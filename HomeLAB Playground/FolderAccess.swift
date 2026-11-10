#if os(macOS)
//
//  FolderAccess.swift
//  HomeLAB Playground
//
//  The folder picker (C-005) and the kept permission to write there (C-016).
//

import AppKit
import Foundation

// REM  C-005, his word 2026-11-09: "it opens a finder in the last download folder but you can navigate to another
// REM  folder to press open." So: a Finder folder window (NSOpenPanel, folders only) that opens AT the last folder you
// REM  picked; you can go anywhere else, then press Open. The pick is remembered as the next starting place.
// REM  C-016: "Lab B asks once for permission to write to the external drive, then keeps it. That's the block we hit
// REM  today." The pick is saved as a security-scoped bookmark — every queued file carries its folder's bookmark — so
// REM  after a quit, a 5 AM restart or a reboot the app writes there again without asking.
// REM  RECENT FOLDERS (build 3, C-021 "Then the MacBook side, for sending links and watching the queue"): the sending
// REM  Mac can't open this Mac's folder window, so this Mac keeps its last few picks (with their bookmarks) and offers
// REM  them over the wire. Choosing one from the sending Mac makes it the last folder here too — C-005: "the app
// REM  remembers your last pick."
@MainActor
enum FolderAccess {
    private static let lastFolderKey = "lastDownloadFolderBookmark"
    private static let recentKey = "recentDownloadFolders"
    /// How many recent folders this Mac keeps and offers to the sending Mac.
    static let recentLimit = 8

    /// A folder picked before, kept with its bookmark so it can be used again without asking (C-016).
    nonisolated struct RecentFolder: Codable, Sendable, Equatable {
        var path: String
        var name: String
        var bookmark: Data
    }
    /// Folders this copy of the app is already holding permission for, by path.
    private static var open: [String: URL] = [:]

    struct Pick {
        var bookmark: Data
        var url: URL
    }

    /// The last folder you picked, with permission held — nil before your first pick.
    static var lastFolder: Pick? {
        guard let data = UserDefaults.standard.data(forKey: lastFolderKey),
              let resolved = resolve(data) else { return nil }
        if resolved.1 != data { UserDefaults.standard.set(resolved.1, forKey: lastFolderKey) }
        return Pick(bookmark: resolved.1, url: resolved.0)
    }

    /// Opens the folder window at the last folder; calls back with your pick, or nil if you cancel.
    static func choose(message: String, then done: @escaping (Pick?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Open"
        // REM  "it opens a finder in the last download folder" — C-005.
        if let last = lastFolder { panel.directoryURL = last.url }
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            else { done(nil); return }
            UserDefaults.standard.set(bookmark, forKey: lastFolderKey)
            hold(url)
            let pick = Pick(bookmark: bookmark, url: url)
            remember(pick)
            done(pick)
        }
    }

    /// Your recent folders, newest first. The first one is the last folder you picked.
    static var recentFolders: [RecentFolder] {
        if let data = UserDefaults.standard.data(forKey: recentKey),
           let list = try? JSONDecoder().decode([RecentFolder].self, from: data), !list.isEmpty {
            return list
        }
        // A Mac that picked its folder before this list existed (build 2) starts the list with that folder.
        guard let data = UserDefaults.standard.data(forKey: lastFolderKey),
              let resolved = resolve(data, mount: false) else { return [] }
        let first = RecentFolder(path: resolved.0.path, name: resolved.0.lastPathComponent, bookmark: resolved.1)
        save([first])
        return [first]
    }

    /// Puts a pick at the top of the recent list and tells the watching Macs.
    static func remember(_ pick: Pick) {
        var list = recentFolders.filter { $0.path != pick.url.path }
        list.insert(RecentFolder(path: pick.url.path, name: pick.url.lastPathComponent, bookmark: pick.bookmark), at: 0)
        save(Array(list.prefix(recentLimit)))
        LinkService.shared.foldersChanged()
    }

    /// A recent folder chosen from the sending Mac. It becomes the last folder here. If its drive isn't connected
    /// right now, the kept bookmark is used anyway — the download waits for the drive and goes on by itself (C-012).
    static func useRecent(path: String) -> Pick? {
        guard let recent = recentFolders.first(where: { $0.path == path }) else { return nil }
        let pick: Pick
        if let resolved = resolve(recent.bookmark) {
            pick = Pick(bookmark: resolved.1, url: resolved.0)
        } else {
            pick = Pick(bookmark: recent.bookmark, url: URL(fileURLWithPath: recent.path, isDirectory: true))
        }
        UserDefaults.standard.set(pick.bookmark, forKey: lastFolderKey)
        remember(pick)
        return pick
    }

    private static func save(_ list: [RecentFolder]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: recentKey) }
    }

    /// Resolves a saved folder and holds permission to write in it. Returns the bookmark to keep (renewed if stale).
    /// Resolving can reconnect a network share that dropped (C-031: reconnect only when needed).
    /// `mount: false` only looks — it never reconnects anything (the morning check's first look).
    static func resolve(_ bookmark: Data, mount: Bool = true) -> (URL, Data)? {
        var stale = false
        var options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        if !mount { options.insert(.withoutMounting) }
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: options,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        hold(url)
        var keep = bookmark
        if stale, let renewed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            keep = renewed
        }
        return (url, keep)
    }

    private static func hold(_ url: URL) {
        guard open[url.path] == nil else { return }
        if url.startAccessingSecurityScopedResource() { open[url.path] = url }
    }

    /// True when the folder is there and this Mac can write in it.
    static func isWritable(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
    }
}
#endif
