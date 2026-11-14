#if os(macOS)
//
//  DownloaderView.swift
//  HomeLAB Playground
//
//  The Mac's window: the role question the first time, then the download queue (or the sender's note).
//

import SwiftUI

// REM  Text is 18 pt at the default size and grows with Dynamic Type (his 18 pt minimum). Every button has a 1–3 word
// REM  accessibility label, says what happens to you, and needs no modifier key. No stubs, no "coming soon".
// REM  C-004: "Paste into the app's window" — the paste box is here so the downloading Mac can be tried on its own
// REM  (C-020: "prove it on the Tranzor Z download") before the sending Mac exists.

struct MacRootView: View {
    @AppStorage(AppRole.key) private var roleRaw = ""

    var body: some View {
        switch AppRole(rawValue: roleRaw) {
        case .download?: DownloaderView()
        case .send?: SenderView()
        case nil: RoleQuestionView()
        }
    }
}

/// The header every Mac window shares: name, build, Settings.
struct HeaderView: View {
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 18

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("HomeLAB Playground")
                    .font(.system(size: titleSize, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("Build \(BuildStamp.buildNumber) · \(BuildStamp.commit)")
                    .font(.system(size: bodySize))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Build \(BuildStamp.buildNumber)")
            }
            Spacer()
            SettingsLink {
                Text("Open Settings").font(.system(size: bodySize))
            }
            .accessibilityLabel("Open settings")
        }
    }
}

// MARK: - First launch

struct RoleQuestionView: View {
    @ScaledMetric(relativeTo: .title3) private var headingSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 18

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderView()
                Divider()
                Text("What does this Mac do?")
                    .font(.system(size: headingSize, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("You choose once. You can change it later in Settings.")
                    .font(.system(size: bodySize))
                ForEach(AppRole.allCases, id: \.self) { role in
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            RoleRunner.choose(role)
                        } label: {
                            Text(role == .send ? "This Mac Sends Links" : "This Mac Downloads")
                                .font(.system(size: bodySize, weight: .semibold))
                        }
                        .accessibilityLabel(role == .send ? "Sends links" : "Downloads")
                        Text(role.explanation)
                            .font(.system(size: bodySize))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Downloading Mac

struct DownloaderView: View {
    @ScaledMetric(relativeTo: .title3) private var headingSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 18
    @State private var linkText = ""
    @State private var message: String?

    private var queue: DownloadQueue { DownloadQueue.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView()
                networkLine
                Divider()
                addBox
                checkLine
                Divider()
                queueList
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear(perform: takeShared)
        .onChange(of: ShareInbox.shared.pending) { _, _ in takeShared() }
    }

    // REM  C-004: a link from Safari's Share menu goes the paste box's way on this Mac: into the box, then the folder
    // REM  window opens so you pick where it goes, just as pressing Choose Folder and Download would.
    private func takeShared() {
        guard let shared = ShareInbox.shared.take() else { return }
        linkText = shared
        add()
    }

    private var networkLine: some View {
        let service = LinkService.shared
        let text: String
        switch service.status {
        case .advertising:
            text = "This Mac downloads. Other Macs on your network find it as “\(LinkService.macName)”."
                + (service.watcherCount > 0 ? " \(service.watcherCount) watching the queue now." : "")
        case .starting: text = "This Mac downloads. It is announcing itself on your network."
        case .blocked(let why): text = "This Mac downloads. \(why) See Local network in Settings."
        case .off: text = "This Mac downloads. It isn’t on your network right now."
        }
        return Text(text).font(.system(size: bodySize)).foregroundStyle(.secondary)
    }

    private var addBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a Download")
                .font(.system(size: headingSize, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Paste a link from archive.org or any download site. An archive.org item downloads as its separate files. Next, a folder window opens at your last download folder; go to any folder you like and press Open.")
                .font(.system(size: bodySize))
                .foregroundStyle(.secondary)
            TextField("Download link", text: $linkText, axis: .vertical)
                .font(.system(size: bodySize))
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .accessibilityLabel("Download link")
                .onSubmit(add)
            Button(action: add) {
                Text("Choose Folder and Download").font(.system(size: bodySize, weight: .semibold))
            }
            .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Choose folder")
            if let message {
                Text(message).font(.system(size: bodySize))
            }
        }
    }

    private var checkLine: some View {
        let check = DriveCheck.shared
        return VStack(alignment: .leading, spacing: 4) {
            if let ran = check.lastRun, let summary = check.summary {
                Text("Drive check at \(ran.formatted(date: .omitted, time: .shortened)): \(summary)")
                    .font(.system(size: bodySize))
                    .foregroundStyle(.secondary)
            }
            if let restart = MorningRestart.lastRestartAt {
                Text("Last 5 AM restart: \(restart.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.system(size: bodySize))
                    .foregroundStyle(.secondary)
            } else {
                Text("Every morning at 5 AM this app pauses its download, restarts itself, checks your drives and goes on.")
                    .font(.system(size: bodySize))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var queueList: some View {
        let items = queue.items
        HStack(alignment: .firstTextBaseline) {
            Text("Queue")
                .font(.system(size: headingSize, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if items.contains(where: \.isFinished) {
                Button {
                    queue.clearFinished()
                } label: {
                    Text("Clear Finished from List").font(.system(size: bodySize))
                }
                .accessibilityLabel("Clear finished")
            }
        }
        if items.isEmpty {
            Text("Nothing is queued. Paste a link above to start.")
                .font(.system(size: bodySize))
                .foregroundStyle(.secondary)
        } else {
            ForEach(sections(items), id: \.key) { section in
                if let group = section.group {
                    GroupHeader(group: group, items: section.items)
                }
                ForEach(section.items) { item in
                    ItemRow(item: item)
                        .padding(.leading, section.group == nil ? 0 : 16)
                }
            }
        }
    }

    private struct QueueSection {
        var key: String
        var group: String?
        var items: [DownloadItem]
    }

    /// Files of one archive.org item sit together under its title, in queue order.
    private func sections(_ items: [DownloadItem]) -> [QueueSection] {
        var result: [QueueSection] = []
        for item in items {
            if let last = result.last, last.group != nil, last.group == item.group {
                result[result.count - 1].items.append(item)
            } else {
                result.append(QueueSection(key: item.id.uuidString, group: item.group, items: [item]))
            }
        }
        return result
    }

    private func add() {
        let links = DownloadQueue.links(in: linkText)
        guard !links.isEmpty else {
            message = "That doesn’t look like a download link. A link starts with http:// or https://."
            return
        }
        FolderAccess.choose(message: "Choose where this download goes, then press Open.") { pick in
            guard let pick else {
                message = "Nothing was added: you closed the folder window without choosing a folder."
                return
            }
            DownloadQueue.shared.add(links, to: pick)
            linkText = ""
            message = links.count == 1
                ? "Added. It goes to the folder “\(pick.url.lastPathComponent)”."
                : "Added \(links.count) links. They go to the folder “\(pick.url.lastPathComponent)”."
        }
    }
}

private struct GroupHeader: View {
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 18
    let group: String
    let items: [DownloadItem]

    var body: some View {
        let done = items.filter(\.isFinished).count
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group).font(.system(size: bodySize, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("\(done) of \(items.count) files done · into \(items.first?.folderName ?? "")/\(group)")
                    .font(.system(size: bodySize))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if done < items.count {
                Button {
                    DownloadQueue.shared.removeUnfinished(inGroup: group)
                } label: {
                    Text("Cancel the Rest").font(.system(size: bodySize))
                }
                .accessibilityLabel("Cancel rest")
            }
        }
        .padding(.top, 8)
    }
}

private struct ItemRow: View {
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 18
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.displayName)
                    .font(.system(size: bodySize, weight: .semibold))
                    .textSelection(.enabled)
                Spacer()
                if item.state == .retrying {
                    Button {
                        DownloadQueue.shared.tryNow(item.id)
                    } label: {
                        Text("Try Again Now").font(.system(size: bodySize))
                    }
                    .accessibilityLabel("Try again")
                }
                Button {
                    DownloadQueue.shared.remove(item.id)
                } label: {
                    Text(item.isFinished ? "Remove from List" : "Cancel Download").font(.system(size: bodySize))
                }
                .accessibilityLabel(item.isFinished ? "Remove from list" : "Cancel download")
            }
            stateView
            if let site = item.site {
                Text(siteLine(site))
                    .font(.system(size: bodySize))
                    .foregroundStyle(.secondary)
            }
            if item.group == nil {
                Text("Into the folder “\(item.folderName)”.")
                    .font(.system(size: bodySize))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var stateView: some View {
        switch item.state {
        case .waiting:
            Text(item.received > 0 ? "Waiting its turn; \(sizeText) already here." : "Waiting its turn.")
                .font(.system(size: bodySize))
        case .checking:
            Text(item.note ?? "Reading what the site says about it.")
                .font(.system(size: bodySize))
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                if let expected = item.expectedSize, expected > 0 {
                    ProgressView(value: Double(min(item.received, expected)), total: Double(expected))
                        .accessibilityLabel("Progress")
                }
                Text("Downloading: \(sizeText).").font(.system(size: bodySize))
            }
        case .verifying:
            Text("Checking it against the site’s size and checksum.")
                .font(.system(size: bodySize))
        case .retrying:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    if let note = item.note { Text(note).font(.system(size: bodySize)) }
                    Text(retryText(now: context.date))
                        .font(.system(size: bodySize))
                        .foregroundStyle(.secondary)
                }
            }
        case .done:
            VStack(alignment: .leading, spacing: 2) {
                Text("Done. Checked: \(item.checkedWith ?? "size").")
                    .font(.system(size: bodySize))
                    .foregroundStyle(.green)
                if let note = item.note { Text(note).font(.system(size: bodySize)) }
            }
        }
    }

    private var sizeText: String {
        let have = DownloadQueue.bytes(item.received)
        guard let expected = item.expectedSize else { return have }
        return "\(have) of \(DownloadQueue.bytes(expected))"
    }

    private func retryText(now: Date) -> String {
        let progress = item.received > 0 ? "\(sizeText) is safe on the drive. " : ""
        guard let next = item.nextTry, next > now else { return progress + "Trying again now." }
        let seconds = Int(next.timeIntervalSince(now).rounded(.up))
        let wait = seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
        return progress + "Trying again in \(wait)."
    }

    private func siteLine(_ site: SiteReport) -> String {
        var parts: [String] = []
        if let type = site.contentType { parts.append(type) }
        if let size = site.size { parts.append(DownloadQueue.bytes(size)) }
        if let changed = site.lastModified { parts.append("changed \(changed)") }
        parts.append(site.resumable ? "can resume" : "can’t resume")
        var line = "The site says: " + parts.joined(separator: " · ") + "."
        if let first = site.firstBytes { line += " Its first bytes say \(first)." }
        return line
    }
}
#endif
