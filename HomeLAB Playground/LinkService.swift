#if os(macOS)
//
//  LinkService.swift
//  HomeLAB Playground
//
//  The downloading Mac announces itself on your home network (Bonjour), takes links, and hands out its queue.
//

import Foundation
import Network
import Observation

// REM  C-011: "The two Macs find each other on your home network by themselves (Apple's Bonjour), with no addresses
// REM  to type." The downloading Mac advertises _homelabplay._tcp under this Mac's own name; the sending Mac (C-021,
// REM  the next piece) browses for it.
// REM  C-014: "The MacBook shows Lab B's queue live" — a Mac that sends {"op":"watch"} gets the whole queue now and again
// REM  every time it changes (at most once a second), on the same connection.
// REM  C-034: the 5 AM restart notice and the "back up" notice ride along in that same queue message ("notice").
// REM  THE WIRE (one JSON object per line, UTF-8, "\n" after each):
// REM    → {"op":"add","link":"<one or more links>"}   ← {"kind":"added","ok":true,"message":"Added to the queue."}
// REM    → {"op":"queue"}                              ← one {"kind":"queue",…}
// REM    → {"op":"watch"}                              ← {"kind":"queue",…} now and after every change
// REM  BUILD 3 ADDITIONS (C-021, "Then the MacBook side, for sending links and watching the queue"). Old messages are
// REM  unchanged; a Mac that doesn't know the new keys ignores them, and the sending Mac only shows a button when the
// REM  queue message lists its op in "ops" — so neither side ever shows a button the other can't carry out.
// REM    → {"op":"add","link":…,"folder":"<path from folders>"}  the link goes into that recent folder instead
// REM    → {"op":"cancel","id":"<item id>"}       ← {"kind":"result","op":"cancel","ok":Bool,"message":String}
// REM    → {"op":"retry","id":"<item id>"}        ← {"kind":"result","op":"retry",…}    (Try Again Now)
// REM    → {"op":"cancelRest","group":"<group>"}  ← {"kind":"result","op":"cancelRest",…}
// REM    → {"op":"clearFinished"}                 ← {"kind":"result","op":"clearFinished",…}
// REM    queue message gains "ops":[…], "destination":{"path","name"}? (where a link goes now) and
// REM    "folders":[{"path","name"},…] (this Mac's recent folders, newest first).
@MainActor
@Observable
final class LinkService {
    static let shared = LinkService()
    static let serviceType = "_homelabplay._tcp"

    enum Status: Equatable {
        case off, starting, advertising, blocked(String)
    }

    private(set) var status: Status = .off
    private(set) var watcherCount = 0
    /// The latest notice to every watching Mac (C-034).
    private(set) var notice: Notice?

    nonisolated struct Notice: Codable, Sendable, Equatable {
        var text: String
        var at: Date
    }

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var watchers: [ObjectIdentifier: NWConnection] = [:]
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var sentRevision = -1

    /// This Mac's name as the other Macs see it.
    static var macName: String { Host.current().localizedName ?? "This Mac" }

    func start() {
        guard listener == nil else { return }
        guard let listener = try? NWListener(using: .tcp) else {
            status = .blocked("This Mac couldn’t open a network port.")
            return
        }
        status = .starting
        listener.service = NWListener.Service(name: Self.macName, type: Self.serviceType)
        listener.stateUpdateHandler = { state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: LinkService.shared.status = .advertising
                    case .waiting(let error), .failed(let error):
                        LinkService.shared.status = .blocked("Other Macs can’t reach this one yet: \(error.localizedDescription)")
                    case .cancelled: LinkService.shared.status = .off
                    default: break
                    }
                }
            }
        }
        listener.newConnectionHandler = { connection in
            DispatchQueue.main.async { MainActor.assumeIsolated { LinkService.shared.accept(connection) } }
        }
        listener.start(queue: .main)
        self.listener = listener

        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let revision = DownloadQueue.shared.revision
                if revision != self.sentRevision {
                    self.sentRevision = revision
                    self.sendToWatchers()
                }
            }
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil
        listener?.cancel()
        listener = nil
        for connection in watchers.values { connection.cancel() }
        watchers.removeAll()
        watcherCount = 0
        status = .off
    }

    /// C-034: tells every watching Mac at once, without waiting for the next queue change.
    func announce(_ text: String) {
        notice = Notice(text: text, at: .now)
        sendToWatchers()
    }

    /// The download folder or the recent list changed: the watching Macs get it at once.
    func foldersChanged() {
        sendToWatchers()
    }

    /// Every op this build answers — the sending Mac shows a control only when its op is listed here.
    static let ops = ["add", "add.folder", "queue", "watch", "cancel", "retry", "cancelRest", "clearFinished"]

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                DispatchQueue.main.async { MainActor.assumeIsolated { LinkService.shared.forget(connection) } }
            default: break
            }
        }
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { chunk, _, complete, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var buffer = buffer
                    if let chunk { buffer.append(chunk) }
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        LinkService.shared.handle(Data(line), from: connection)
                    }
                    if complete || error != nil || buffer.count > 1_048_576 {
                        connection.cancel()
                    } else {
                        LinkService.shared.receive(on: connection, buffer: buffer)
                    }
                }
            }
        }
    }

    private func handle(_ line: Data, from connection: NWConnection) {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let op = request["op"] as? String else { return }
        switch op {
        case "add":
            let result = DownloadQueue.shared.addFromNetwork((request["link"] as? String) ?? "",
                                                            folderPath: request["folder"] as? String)
            send(["kind": "added", "ok": result.ok, "message": result.message], to: connection)
        case "cancel":
            let queue = DownloadQueue.shared
            guard let id = (request["id"] as? String).flatMap(UUID.init(uuidString:)), queue.contains(id) else {
                reply(op, ok: false, "That file isn’t in the queue anymore.", to: connection)
                return
            }
            let wasDone = queue.items.first { $0.id == id }?.isFinished ?? false
            queue.remove(id)
            reply(op, ok: true, wasDone ? "Removed from the list. The file stays in its folder." : "Download canceled.", to: connection)
        case "retry":
            let queue = DownloadQueue.shared
            guard let id = (request["id"] as? String).flatMap(UUID.init(uuidString:)), queue.isRetrying(id) else {
                reply(op, ok: false, "That file isn’t waiting to try again anymore.", to: connection)
                return
            }
            queue.tryNow(id)
            reply(op, ok: true, "Trying again now.", to: connection)
        case "cancelRest":
            guard let group = request["group"] as? String,
                  DownloadQueue.shared.items.contains(where: { $0.group == group && !$0.isFinished }) else {
                reply(op, ok: false, "Nothing is left to cancel there.", to: connection)
                return
            }
            DownloadQueue.shared.removeUnfinished(inGroup: group)
            reply(op, ok: true, "The rest of “\(group)” is canceled.", to: connection)
        case "clearFinished":
            DownloadQueue.shared.clearFinished()
            reply(op, ok: true, "Finished files cleared from the list. The files stay in their folders.", to: connection)
        case "queue":
            send(snapshot(), to: connection)
        case "watch":
            watchers[ObjectIdentifier(connection)] = connection
            watcherCount = watchers.count
            send(snapshot(), to: connection)
        default:
            break
        }
    }

    private func reply(_ op: String, ok: Bool, _ message: String, to connection: NWConnection) {
        send(["kind": "result", "op": op, "ok": ok, "message": message], to: connection)
    }

    private func forget(_ connection: NWConnection) {
        watchers[ObjectIdentifier(connection)] = nil
        watcherCount = watchers.count
    }

    private func sendToWatchers() {
        guard !watchers.isEmpty else { return }
        let message = snapshot()
        for connection in watchers.values { send(message, to: connection) }
    }

    private func send(_ message: [String: Any], to connection: NWConnection) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// The whole queue, as the sending Mac will show it (C-014).
    private func snapshot() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var message: [String: Any] = [
            "kind": "queue",
            "mac": Self.macName,
            "build": BuildStamp.buildNumber,
            "items": DownloadQueue.shared.items.map { item -> [String: Any] in
                var row: [String: Any] = [
                    "id": item.id.uuidString,
                    "name": item.displayName,
                    "state": item.state.rawValue,
                    "received": item.received,
                    "folder": item.folderName,
                ]
                if let group = item.group { row["group"] = group }
                if let size = item.expectedSize { row["size"] = size }
                if let note = item.note { row["note"] = note }
                if let checked = item.checkedWith { row["checked"] = checked }
                if let next = item.nextTry, item.state == .retrying { row["nextTry"] = iso.string(from: next) }
                if let finished = item.finished { row["finished"] = iso.string(from: finished) }
                return row
            },
        ]
        if let notice { message["notice"] = ["text": notice.text, "at": iso.string(from: notice.at)] }
        message["ops"] = Self.ops
        let folders = FolderAccess.recentFolders
        message["folders"] = folders.map { ["path": $0.path, "name": $0.name] }
        if let now = folders.first { message["destination"] = ["path": now.path, "name": now.name] }
        return message
    }
}
#endif
