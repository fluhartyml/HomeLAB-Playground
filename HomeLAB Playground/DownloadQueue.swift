#if os(macOS)
//
//  DownloadQueue.swift
//  HomeLAB Playground
//
//  The downloading Mac's queue: one file at a time, resumed, retried, checked, and kept on disk across relaunches.
//

import Foundation
import Observation

// REM  C-012, locked 2026-11-09: "Lab B never gives up. It resumes a half-finished file where it stopped, waits and
// REM  retries when the Archive is offline (like today), and starts again on its own after Lab B restarts."
// REM    • resumes  — ResumingDownload asks only for the bytes missing from <name>.part.
// REM    • retries  — every failure waits 15 s, 30 s, 1 min … up to 10 min between tries, forever. There is no "failed"
// REM                 state on purpose: a line leaves the queue only when it is done or you cancel it.
// REM    • restarts — the queue is saved to disk on every change and picked up at launch; Open at Login (Settings)
// REM                 starts the app after the Mac restarts.
// REM  C-013: "A file only counts as done when both match" — size, and the checksum when the site gives one (C-002).
// REM  ONE FILE AT A TIME (Claude's call, the sheet doesn't say): gentle on archive.org, and a drop costs one file.
@MainActor
@Observable
final class DownloadQueue {
    static let shared = DownloadQueue()

    private(set) var items: [DownloadItem] = []
    /// Bumped on every change, so the network service knows when to send the queue again.
    private(set) var revision = 0

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var currentID: UUID?
    @ObservationIgnored private var currentDownload: Task<ResumingDownload.Outcome, Never>?
    @ObservationIgnored private var stalledID: UUID?
    @ObservationIgnored private var lastProgressAt = Date.now
    @ObservationIgnored private var holding = false
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var loaded = false

    /// Seconds without a single byte before a download counts as stalled and reconnects.
    static let stallSeconds: TimeInterval = 90

    nonisolated static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "HomeLAB Playground", directoryHint: .isDirectory)
            .appending(path: "Queue.json", directoryHint: .notDirectory)
    }

    // MARK: Start and stop

    func start() {
        if !loaded { load() }
        holding = false
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.keepAwakeWhileWorking()
                if !self.holding, let next = self.nextID() {
                    self.busy = true
                    await self.process(next)
                    self.busy = false
                } else {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// Stops downloading (this Mac was switched to Send links). Files in progress stay on the drive to resume later.
    func stop() {
        holding = true
        currentDownload?.cancel()
        loop?.cancel()
        loop = nil
        keepAwakeWhileWorking()
    }

    /// C-033: "once the file in progress is safely paused" — stops the current download and waits for it to let go.
    func pauseForRestart() async {
        holding = true
        currentDownload?.cancel()
        let end = Date.now.addingTimeInterval(120)
        while busy, Date.now < end { try? await Task.sleep(for: .milliseconds(200)) }
        save()
    }

    // MARK: Adding

    /// Every http(s) link in the text — you can paste one or many.
    static func links(in text: String) -> [URL] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { word in
            guard let url = URL(string: String(word)), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host() != nil else { return nil }
            return url
        }
    }

    func add(_ links: [URL], to folder: FolderAccess.Pick) {
        let folderName = folder.url.lastPathComponent
        for link in links {
            if let archive = ArchiveOrg.parse(link) {
                items.append(DownloadItem(kind: .archiveItem, link: link, name: archive.identifier, onlyFile: archive.file,
                                          folderBookmark: folder.bookmark, folderName: folderName))
            } else {
                let fromLink = link.lastPathComponent.removingPercentEncoding ?? link.lastPathComponent
                let name = Self.cleanPath(fromLink == "/" ? "" : fromLink)
                items.append(DownloadItem(kind: .file, link: link, name: name.isEmpty ? "download" : name,
                                          folderBookmark: folder.bookmark, folderName: folderName))
            }
        }
        save()
        start()
    }

    /// A link sent from another Mac (LinkService). It goes to the recent folder the sending Mac chose, or else to the
    /// last folder picked on this Mac.
    func addFromNetwork(_ text: String, folderPath: String? = nil) -> (ok: Bool, message: String) {
        let found = Self.links(in: text)
        guard !found.isEmpty else { return (false, "That isn’t a download link.") }
        let folder: FolderAccess.Pick
        if let folderPath {
            guard let recent = FolderAccess.useRecent(path: folderPath) else {
                return (false, "That folder isn’t in the downloading Mac’s recent folders anymore. Choose another one.")
            }
            folder = recent
        } else {
            guard let last = FolderAccess.lastFolder else {
                return (false, "The downloading Mac has no download folder yet. Pick one on that Mac first.")
            }
            folder = last
        }
        add(found, to: folder)
        let into = "into “\(folder.url.lastPathComponent)”"
        return (true, found.count == 1 ? "Added to the queue, \(into)." : "Added \(found.count) links to the queue, \(into).")
    }

    /// True when the queue has a line with this id.
    func contains(_ id: UUID) -> Bool { items.contains { $0.id == id } }

    /// True when this line is waiting to try again (so Try Again Now means something).
    func isRetrying(_ id: UUID) -> Bool { items.first { $0.id == id }?.state == .retrying }

    // MARK: Changing the list

    /// Cancels a file that isn't done (its half-finished part is deleted), or clears a finished one from the list
    /// (the finished file stays in its folder).
    func remove(_ id: UUID) {
        guard let item = item(id) else { return }
        if currentID == id { currentDownload?.cancel() }
        if !item.isFinished, item.kind == .file, let folder = FolderAccess.resolve(item.folderBookmark)?.0 {
            try? FileManager.default.removeItem(at: Self.partURL(Self.destination(item, in: folder)))
        }
        items.removeAll { $0.id == id }
        save()
    }

    func removeUnfinished(inGroup group: String) {
        for item in items where item.group == group && !item.isFinished { remove(item.id) }
    }

    func clearFinished() {
        items.removeAll { $0.isFinished }
        save()
    }

    func tryNow(_ id: UUID) {
        update(id) { $0.nextTry = .now }
    }

    // MARK: The work

    private func nextID() -> UUID? {
        items.first { item in
            switch item.state {
            case .done: return false
            case .retrying: return (item.nextTry ?? .distantPast) <= .now
            default: return true
            }
        }?.id
    }

    private func process(_ id: UUID) async {
        guard let item = item(id) else { return }
        switch item.kind {
        case .archiveItem: await expand(id)
        case .file: await download(id)
        }
    }

    /// An archive.org link becomes one line per file (C-003).
    private func expand(_ id: UUID) async {
        guard let item = item(id) else { return }
        update(id) { $0.state = .checking; $0.note = "Reading the item’s file list from archive.org." }
        do {
            let listing = try await ArchiveOrg.listing(for: ArchiveOrg.Link(identifier: item.name, file: item.onlyFile))
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            let parent = items[index]
            let title = Self.cleanName(listing.title)
            let group: String? = parent.onlyFile == nil ? (title.isEmpty ? parent.name : title) : nil
            let files = listing.files.map { file in
                DownloadItem(kind: .file, link: file.url, name: Self.cleanPath(file.name), group: group,
                             folderBookmark: parent.folderBookmark, folderName: parent.folderName, nameSettled: true,
                             expectedSize: file.size, md5: file.md5, sha1: file.sha1)
            }
            items.replaceSubrange(index...index, with: files)
            save()
        } catch {
            retry(id, error.localizedDescription)
        }
    }

    private func download(_ id: UUID) async {
        guard let first = item(id) else { return }
        guard let resolved = FolderAccess.resolve(first.folderBookmark), FolderAccess.isWritable(resolved.0) else {
            retry(id, "This Mac can’t reach the folder “\(first.folderName)”. Connect its drive; the download goes on by itself once it’s back.")
            return
        }
        let folder = resolved.0
        if resolved.1 != first.folderBookmark { update(id) { $0.folderBookmark = resolved.1 } }

        // 1. Read what the site says about the file, once, before downloading it.
        if first.site == nil {
            update(id) { $0.state = .checking; $0.note = nil }
            do {
                let check = try await SiteCheck.run(first.link)
                update(id) { item in
                    item.site = check.report
                    if item.expectedSize == nil { item.expectedSize = check.report.size }
                    if item.md5 == nil { item.md5 = check.md5 }
                    if item.sha1 == nil { item.sha1 = check.sha1 }
                    if item.sha256 == nil { item.sha256 = check.sha256 }
                    if !item.nameSettled, item.received == 0, let suggested = check.report.suggestedName {
                        let clean = Self.cleanName(suggested)
                        if !clean.isEmpty { item.name = clean }
                    }
                    item.nameSettled = true
                }
            } catch {
                retry(id, error.localizedDescription)
                return
            }
        }
        guard let checked = item(id), let site = checked.site else { return }
        if site.status >= 400 {
            update(id) { $0.site = nil }
            retry(id, "The site answered \(site.status) \(HTTPURLResponse.localizedString(forStatusCode: site.status)).")
            return
        }
        if site.looksLikeWebPage {
            update(id) { $0.site = nil }
            retry(id, "The site sent a web page, not the file. If this keeps happening, cancel it and paste the file’s own download link.")
            return
        }

        // 2. Where it goes. A file already there from before is checked, never overwritten.
        var item = checked
        var destination = Self.destination(item, in: folder)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !Self.exists(Self.partURL(destination)), Self.exists(destination) {
            if item.expectedSize != nil || item.md5 != nil || item.sha1 != nil || item.sha256 != nil,
               case .success(let what) = await verify(destination, against: item) {
                finish(id, checkedWith: what, note: "It was already in the folder and checks out.")
                return
            }
            let free = Self.freeName(for: destination)
            update(id) { item in
                let subfolder = (item.name as NSString).deletingLastPathComponent
                item.name = subfolder.isEmpty ? free : subfolder + "/" + free
            }
            guard let renamed = self.item(id) else { return }
            item = renamed
            destination = Self.destination(item, in: folder)
        }
        let part = Self.partURL(destination)

        // 3. Download, picking up where the .part ends.
        let startedWith = Self.size(of: part)
        update(id) { $0.state = .downloading; $0.received = startedWith; $0.note = nil }
        let downloader = ResumingDownload(part: part) { have in
            Task { @MainActor in DownloadQueue.shared.progressed(id, have) }
        }
        let link = item.link
        let task = Task { await downloader.run(from: link) }
        currentID = id
        currentDownload = task
        stalledID = nil
        lastProgressAt = .now
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                if Date.now.timeIntervalSince(self.lastProgressAt) > Self.stallSeconds {
                    self.stalledID = id
                    task.cancel()
                    return
                }
            }
        }
        let outcome = await task.value
        watchdog.cancel()
        currentID = nil
        currentDownload = nil
        let have = Self.size(of: part)
        guard self.item(id) != nil else { return }          // cancelled from the list
        if holding, stalledID != id {
            update(id) { $0.state = .waiting; $0.received = have }
            return
        }
        if have > startedWith { update(id) { $0.failures = 0 } }

        var total: Int64?
        var nothingMore = false
        switch outcome {
        case .failed(let why):
            update(id) { $0.received = have }
            retry(id, stalledID == id
                  ? "Nothing arrived for \(Int(Self.stallSeconds)) seconds, so it reconnects and picks up where it stopped."
                  : why)
            return
        case .complete(let t):
            total = t
        case .nothingMore(let t):
            total = t
            nothingMore = true
        }
        if self.item(id)?.expectedSize == nil, let total { update(id) { $0.expectedSize = total } }
        guard let done = self.item(id) else { return }

        // 4. Size first (C-013).
        if let expected = done.expectedSize {
            if have < expected && !nothingMore {
                update(id) { $0.received = have }
                retry(id, "The connection ended at \(Self.bytes(have)) of \(Self.bytes(expected)); it picks up where it stopped.")
                return
            }
            if have != expected {
                try? FileManager.default.removeItem(at: part)
                update(id) { $0.received = 0 }
                retry(id, "The file came out \(Self.bytes(have)) but the site lists \(Self.bytes(expected)), so it downloads again.")
                return
            }
        }

        // 5. Then the checksum, when the site gave one.
        update(id) { $0.state = .verifying; $0.received = have; $0.note = nil }
        switch await verify(part, against: done) {
        case .failure(let mismatch):
            try? FileManager.default.removeItem(at: part)
            update(id) { $0.received = 0 }
            retry(id, mismatch.reason)
        case .success(let what):
            var target = destination
            if Self.exists(target) { target = target.deletingLastPathComponent().appending(path: Self.freeName(for: target)) }
            do {
                try FileManager.default.moveItem(at: part, to: target)
                finish(id, checkedWith: what, note: nil)
            } catch {
                retry(id, "The file is whole but couldn’t be put in place: \(error.localizedDescription)")
            }
        }
    }

    struct Mismatch: Error { var reason: String }

    /// Size, then every checksum the site gave. Success says what was checked ("size and MD5").
    private func verify(_ file: URL, against item: DownloadItem) async -> Result<String, Mismatch> {
        var checked: [String] = []
        if let expected = item.expectedSize {
            let size = Self.size(of: file)
            guard size == expected else {
                return .failure(Mismatch(reason: "The file is \(Self.bytes(size)) but the site lists \(Self.bytes(expected)), so it downloads again."))
            }
            checked.append("size")
        }
        let wantMD5 = item.md5 != nil, wantSHA1 = item.sha1 != nil, wantSHA256 = item.sha256 != nil
        if wantMD5 || wantSHA1 || wantSHA256 {
            let digests: FileVerifier.Digests
            do {
                digests = try await Task.detached(priority: .utility) {
                    try FileVerifier.digests(of: file, md5: wantMD5, sha1: wantSHA1, sha256: wantSHA256)
                }.value
            } catch {
                return .failure(Mismatch(reason: "This Mac couldn’t read the file back to check it: \(error.localizedDescription)"))
            }
            for (name, want, got) in [("MD5", item.md5, digests.md5), ("SHA-1", item.sha1, digests.sha1),
                                      ("SHA-256", item.sha256, digests.sha256)] {
                guard let want else { continue }
                guard want.lowercased() == got else {
                    return .failure(Mismatch(reason: "The \(name) checksum didn’t match what the site lists, so it downloads again."))
                }
                checked.append(name)
            }
        }
        if checked.isEmpty { return .success("nothing — the site gave no size or checksum") }
        return .success(ListFormatter.localizedString(byJoining: checked))
    }

    private func finish(_ id: UUID, checkedWith: String, note: String?) {
        update(id) { item in
            item.state = .done
            item.finished = .now
            item.failures = 0
            item.nextTry = nil
            item.note = note
            item.checkedWith = checkedWith
            if let size = item.expectedSize { item.received = size }
        }
    }

    /// Waits 15 s, 30 s, 1 min, 2 min, 4 min, then every 10 min — and never gives up (C-012).
    private func retry(_ id: UUID, _ why: String) {
        update(id) { item in
            item.failures += 1
            let wait = min(600, 15 * pow(2, Double(min(item.failures - 1, 10))))
            item.state = .retrying
            item.nextTry = Date.now.addingTimeInterval(wait)
            item.note = why
        }
    }

    private func progressed(_ id: UUID, _ have: Int64) {
        lastProgressAt = .now
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .downloading else { return }
        items[index].received = have
        revision += 1
    }

    // MARK: Keeping the Mac awake

    // REM  A Mac that naps or sleeps mid-download looks exactly like a site that stopped answering. While anything is
    // REM  waiting to download, the app tells macOS it is doing work you asked for, so it isn't napped or put to sleep.
    private func keepAwakeWhileWorking() {
        let working = !holding && items.contains { !$0.isFinished }
        if working, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Downloading files you queued")
        } else if !working, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    // MARK: Disk

    private func load() {
        loaded = true
        guard let data = try? Data(contentsOf: Self.fileURL),
              let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        // Anything that was mid-way when the app stopped simply goes again; the .part on the drive holds its place.
        items = saved.map { item in
            var item = item
            if [.checking, .downloading, .verifying].contains(item.state) { item.state = .waiting }
            return item
        }
        revision += 1
    }

    private func save() {
        revision += 1
        do {
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: Self.fileURL, options: .atomic)
        } catch {
            // Nothing to show: the queue in memory still runs; the next change tries to save again.
        }
    }

    private func item(_ id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save()
    }

    // MARK: Paths and names

    nonisolated static func destination(_ item: DownloadItem, in folder: URL) -> URL {
        var directory = folder
        if let group = item.group { directory = directory.appending(path: group, directoryHint: .isDirectory) }
        return directory.appending(path: item.name, directoryHint: .notDirectory)
    }

    nonisolated static func partURL(_ destination: URL) -> URL {
        destination.deletingLastPathComponent().appending(path: destination.lastPathComponent + ".part", directoryHint: .notDirectory)
    }

    /// A single file or folder name that is safe on disk.
    nonisolated static func cleanName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.drop { $0 == "." }
        return String(trimmed.prefix(200))
    }

    /// A relative path (an archive.org item can hold subfolders) with nothing that climbs out of the folder.
    nonisolated static func cleanPath(_ path: String) -> String {
        path.split(separator: "/").map { cleanName(String($0)) }.filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// "Episode 1 2.mp4", "Episode 1 3.mp4" … — the first name not already taken (with or without .part).
    nonisolated static func freeName(for url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = folder.appending(path: name)
            if !exists(candidate), !exists(partURL(candidate)) { return name }
            n += 1
        }
    }

    nonisolated static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    nonisolated static func size(of url: URL) -> Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
    }

    nonisolated static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
#endif
