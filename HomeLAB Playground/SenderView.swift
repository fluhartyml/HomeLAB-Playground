#if os(macOS)
//
//  SenderView.swift
//  HomeLAB Playground
//
//  The sending Mac's window: which Mac downloads, its notices, the paste box, and its queue live.
//

import SwiftUI

// REM  C-021: "Then the MacBook side, for sending links and watching the queue."
// REM  C-004: "Paste into the app's window" — the paste box. (Safari's Share menu, the other half of C-004, needs its
// REM  own Share extension target; it is not in this build.)
// REM  C-005 on this side: this Mac can't open the downloading Mac's folder window, so it shows where the link will go
// REM  and lets you pick from that Mac's recent folders. A folder that isn't listed is picked once on that Mac.
// REM  C-014: "each file, how far along it is, and which are done" — the same rows the downloading Mac shows, with
// REM  Cancel and Try Again working over the wire. A button only appears when the downloading Mac lists its op, and
// REM  it is grayed out while the connection is down, so no button ever does nothing.
// REM  Text 18 pt and up with Dynamic Type; every control has a 1–3 word accessibility label; no modifier keys.
struct SenderView: View {
    @ScaledMetric(relativeTo: .title3) private var headingSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 18
    @State private var linkText = ""
    @State private var folderPick: String?
    @State private var localMessage: String?

    private var link: DownloaderLink { DownloaderLink.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView()
                connectionBox
                if let notice = link.notice { noticeBox(notice) }
                Divider()
                sendBox
                Divider()
                queueList
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear { link.start() }
        .onChange(of: link.addReply?.ok) { _, ok in
            if ok == true { linkText = "" }
        }
    }

    // MARK: Which Mac downloads

    private var connectionText: String {
        switch link.status {
        case .off, .looking:
            return link.found.isEmpty
                ? "Looking on your network for a Mac set to Download. Open HomeLAB Playground on that Mac."
                : "Looking for the Mac you picked. It may be asleep or restarting."
        case .choosing: return "More than one Mac on your network downloads. Pick the one to send to."
        case .connecting(let name): return "Connecting to “\(name)”."
        case .connected(let name): return "Connected to “\(name)”. Links you send here download there."
        case .blocked(let why): return "\(why) See Local network in Settings."
        }
    }

    /// The Mac shown as picked: your pick if it's on the network, else the one this Mac is talking to now.
    private var pickedMac: String {
        if let chosen = link.chosenName, link.found.contains(chosen) { return chosen }
        switch link.status {
        case .connected(let name), .connecting(let name): return link.found.contains(name) ? name : ""
        default: return ""
        }
    }

    private var connectionBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(connectionText)
                .font(.system(size: bodySize))
                .foregroundStyle(link.isConnected ? .primary : .secondary)
            if link.found.count > 1 {
                Picker(selection: Binding(
                    get: { pickedMac },
                    set: { link.chosenName = $0.isEmpty ? nil : $0 }
                )) {
                    if pickedMac.isEmpty {
                        Text("Pick a Mac").font(.system(size: bodySize)).tag("")
                    }
                    ForEach(link.found, id: \.self) { name in
                        Text(name).font(.system(size: bodySize)).tag(name)
                    }
                } label: {
                    Text("Send to").font(.system(size: bodySize))
                }
                .pickerStyle(.radioGroup)
                .accessibilityLabel("Downloading Mac")
            }
        }
    }

    private func noticeBox(_ notice: DownloaderLink.Notice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notice from \(notice.from) at \(notice.at.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: bodySize, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(notice.text).font(.system(size: bodySize))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    // MARK: Sending

    private var sendBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send a Download")
                .font(.system(size: headingSize, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Paste a link from archive.org or any download site. You can paste several at once.")
                .font(.system(size: bodySize))
                .foregroundStyle(.secondary)
            TextField("Download link", text: $linkText, axis: .vertical)
                .font(.system(size: bodySize))
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .accessibilityLabel("Download link")
                .onSubmit(send)
            folderLine
            Button(action: send) {
                Text(link.macName.map { "Send to \($0)" } ?? "Send Link")
                    .font(.system(size: bodySize, weight: .semibold))
            }
            .disabled(!link.isConnected || link.sending || linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send link")
            if let localMessage {
                Text(localMessage).font(.system(size: bodySize))
            } else if link.sending {
                Text("Sending.").font(.system(size: bodySize)).foregroundStyle(.secondary)
            } else if let reply = link.addReply {
                Text(reply.message)
                    .font(.system(size: bodySize))
                    .foregroundStyle(reply.ok ? .green : .orange)
            }
        }
    }

    @ViewBuilder
    private var folderLine: some View {
        let mac = link.macName ?? "The downloading Mac"
        if link.can("add.folder"), link.folders.count > 1 {
            Picker(selection: Binding(
                get: { chosenFolderPath ?? "" },
                set: { folderPick = $0 }
            )) {
                ForEach(link.folders) { folder in
                    Text("\(folder.name)  (\(folder.path))").font(.system(size: bodySize)).tag(folder.path)
                }
            } label: {
                Text("Into the folder").font(.system(size: bodySize))
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Download folder")
            Text("These are the folders you picked last on \(mac). To use a different folder, pick it once in the folder window on \(mac).")
                .font(.system(size: bodySize))
                .foregroundStyle(.secondary)
        } else if let destination = link.destination {
            Text("It goes into the folder “\(destination.name)” (\(destination.path)) on \(mac), the folder you picked last there.")
                .font(.system(size: bodySize))
                .foregroundStyle(.secondary)
        } else if link.isConnected {
            Text("It goes into the folder you picked last on \(mac).")
                .font(.system(size: bodySize))
                .foregroundStyle(.secondary)
        }
    }

    /// Your pick from the recent folders, or where the downloading Mac puts links now.
    private var chosenFolderPath: String? {
        if let folderPick, link.folders.contains(where: { $0.path == folderPick }) { return folderPick }
        return link.destination?.path ?? link.folders.first?.path
    }

    private func send() {
        guard link.isConnected, !link.sending else { return }
        guard !DownloadQueue.links(in: linkText).isEmpty else {
            localMessage = "That doesn’t look like a download link. A link starts with http:// or https://."
            return
        }
        localMessage = nil
        // Only name a folder when you can pick one; otherwise the downloading Mac uses its last folder.
        let folder = link.can("add.folder") && link.folders.count > 1 ? chosenFolderPath : nil
        link.sendLinks(linkText, folder: folder)
    }

    // MARK: The queue, live

    @ViewBuilder
    private var queueList: some View {
        let items = link.items
        HStack(alignment: .firstTextBaseline) {
            Text(link.macName.map { "Queue on \($0)" } ?? "Queue")
                .font(.system(size: headingSize, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if link.ops.contains("clearFinished"), items.contains(where: \.isDone) {
                Button {
                    link.clearFinished()
                } label: {
                    Text("Clear Finished from List").font(.system(size: bodySize))
                }
                .disabled(!link.isConnected)
                .accessibilityLabel("Clear finished")
            }
        }
        if !link.isConnected, let at = link.queueAt {
            Text("You’re not connected right now. This is the queue as of \(at.formatted(date: .omitted, time: .shortened)); it updates by itself when the connection is back.")
                .font(.system(size: bodySize))
                .foregroundStyle(.orange)
        }
        if let reply = link.actionReply {
            Text(reply.message)
                .font(.system(size: bodySize))
                .foregroundStyle(reply.ok ? .secondary : Color.orange)
        }
        if link.queueAt == nil {
            Text("The queue shows here once you’re connected.")
                .font(.system(size: bodySize))
                .foregroundStyle(.secondary)
        } else if items.isEmpty {
            Text("Nothing is queued. Paste a link above to start.")
                .font(.system(size: bodySize))
                .foregroundStyle(.secondary)
        } else {
            ForEach(sections(items), id: \.key) { section in
                if let group = section.group {
                    RemoteGroupHeader(group: group, items: section.items)
                }
                ForEach(section.items) { item in
                    RemoteItemRow(item: item)
                        .padding(.leading, section.group == nil ? 0 : 16)
                }
            }
        }
    }

    private struct QueueSection {
        var key: String
        var group: String?
        var items: [DownloaderLink.Item]
    }

    /// Files of one archive.org item sit together under its title, in queue order (as on the downloading Mac).
    private func sections(_ items: [DownloaderLink.Item]) -> [QueueSection] {
        var result: [QueueSection] = []
        for item in items {
            if let last = result.last, last.group != nil, last.group == item.group {
                result[result.count - 1].items.append(item)
            } else {
                result.append(QueueSection(key: item.id, group: item.group, items: [item]))
            }
        }
        return result
    }
}

private struct RemoteGroupHeader: View {
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 18
    let group: String
    let items: [DownloaderLink.Item]
    private var link: DownloaderLink { DownloaderLink.shared }

    var body: some View {
        let done = items.filter(\.isDone).count
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group).font(.system(size: bodySize, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("\(done) of \(items.count) files done · into \(items.first?.folder ?? "")/\(group)")
                    .font(.system(size: bodySize))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if done < items.count, link.ops.contains("cancelRest") {
                Button {
                    link.cancelRest(of: group)
                } label: {
                    Text("Cancel the Rest").font(.system(size: bodySize))
                }
                .disabled(!link.isConnected)
                .accessibilityLabel("Cancel rest")
            }
        }
        .padding(.top, 8)
    }
}

private struct RemoteItemRow: View {
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 18
    let item: DownloaderLink.Item
    private var link: DownloaderLink { DownloaderLink.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name)
                    .font(.system(size: bodySize, weight: .semibold))
                    .textSelection(.enabled)
                Spacer()
                if item.state == "retrying", link.ops.contains("retry") {
                    Button {
                        link.tryAgain(item)
                    } label: {
                        Text("Try Again Now").font(.system(size: bodySize))
                    }
                    .disabled(!link.isConnected)
                    .accessibilityLabel("Try again")
                }
                if link.ops.contains("cancel") {
                    Button {
                        link.cancel(item)
                    } label: {
                        Text(item.isDone ? "Remove from List" : "Cancel Download").font(.system(size: bodySize))
                    }
                    .disabled(!link.isConnected)
                    .accessibilityLabel(item.isDone ? "Remove from list" : "Cancel download")
                }
            }
            stateView
            if item.group == nil {
                Text("Into the folder “\(item.folder)”.")
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
        case "waiting":
            Text(item.received > 0 ? "Waiting its turn; \(sizeText) already there." : "Waiting its turn.")
                .font(.system(size: bodySize))
        case "checking":
            Text(item.note ?? "Reading what the site says about it.")
                .font(.system(size: bodySize))
        case "downloading":
            VStack(alignment: .leading, spacing: 4) {
                if let expected = item.size, expected > 0 {
                    ProgressView(value: Double(min(item.received, expected)), total: Double(expected))
                        .accessibilityLabel("Progress")
                }
                Text("Downloading: \(sizeText).").font(.system(size: bodySize))
            }
        case "verifying":
            Text("Checking it against the site’s size and checksum.")
                .font(.system(size: bodySize))
        case "retrying":
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    if let note = item.note { Text(note).font(.system(size: bodySize)) }
                    Text(retryText(now: context.date))
                        .font(.system(size: bodySize))
                        .foregroundStyle(.secondary)
                }
            }
        case "done":
            VStack(alignment: .leading, spacing: 2) {
                Text("Done. Checked: \(item.checked ?? "size").")
                    .font(.system(size: bodySize))
                    .foregroundStyle(.green)
                if let note = item.note { Text(note).font(.system(size: bodySize)) }
            }
        default:
            Text(item.note ?? sizeText).font(.system(size: bodySize))
        }
    }

    private var sizeText: String {
        let have = DownloadQueue.bytes(item.received)
        guard let expected = item.size else { return have }
        return "\(have) of \(DownloadQueue.bytes(expected))"
    }

    private func retryText(now: Date) -> String {
        let progress = item.received > 0 ? "\(sizeText) is safe on the drive. " : ""
        guard let next = item.nextTry, next > now else { return progress + "Trying again now." }
        let seconds = Int(next.timeIntervalSince(now).rounded(.up))
        let wait = seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
        return progress + "Trying again in \(wait)."
    }
}
#endif
