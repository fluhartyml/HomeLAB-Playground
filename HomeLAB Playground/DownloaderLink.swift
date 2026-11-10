#if os(macOS)
//
//  DownloaderLink.swift
//  HomeLAB Playground
//
//  The sending Mac's side of the wire: finds the downloading Mac by Bonjour, sends links, and keeps its queue live.
//

import Foundation
import Network
import Observation

// REM  C-021, his word 2026-11-09 20:0x: "yes lock the plan." — "Then the MacBook side, for sending links and watching
// REM  the queue."
// REM  C-011: "The two Macs find each other on your home network by themselves (Apple's Bonjour), with no addresses to
// REM  type." This browses for _homelabplay._tcp (the service LinkService advertises). No name is written in: if one
// REM  downloading Mac is found it is used; if several are found, you pick one, and your pick is remembered.
// REM  C-014: "The MacBook shows Lab B's queue live: each file, how far along it is, and which are done." One
// REM  connection: {"op":"watch"} first, then every add / cancel / retry goes down the same line.
// REM  C-034: Lab B's "restarting … back in about a minute" and "back up" notices arrive inside the queue message. The
// REM  restart drops the connection; this Mac keeps the last notice and the last queue on screen, keeps browsing, and
// REM  reconnects by itself when the downloading Mac comes back.
@MainActor
@Observable
final class DownloaderLink {
    static let shared = DownloaderLink()
    static let chosenKey = "chosenDownloadingMac"

    enum Status: Equatable {
        case off
        /// Browsing; no downloading Mac found yet (or the one you picked is gone for now).
        case looking
        /// More than one downloading Mac is on the network and you haven't picked one.
        case choosing
        case connecting(String)
        case connected(String)
        /// This Mac can't browse the network (Local Network permission, usually).
        case blocked(String)
    }

    nonisolated struct Item: Identifiable, Sendable, Equatable {
        var id: String
        var name: String
        var state: String
        var received: Int64
        var size: Int64?
        var group: String?
        var folder: String
        var note: String?
        var checked: String?
        var nextTry: Date?
        var finished: Date?
        var isDone: Bool { state == "done" }
    }

    nonisolated struct Folder: Identifiable, Sendable, Equatable, Hashable {
        var path: String
        var name: String
        var id: String { path }
    }

    nonisolated struct Notice: Sendable, Equatable {
        var text: String
        var at: Date
        var from: String
    }

    private(set) var status: Status = .off
    /// Names of the downloading Macs on your network right now, sorted.
    private(set) var found: [String] = []
    /// The Mac the queue below came from.
    private(set) var macName: String?
    private(set) var items: [Item] = []
    /// When the queue below was last heard — shown when the connection is down.
    private(set) var queueAt: Date?
    /// What the downloading Mac says it can do (its "ops"); a button is shown only when its op is here.
    private(set) var ops: Set<String> = []
    /// Where a link goes right now, and the downloading Mac's recent folders (newest first).
    private(set) var destination: Folder?
    private(set) var folders: [Folder] = []
    private(set) var notice: Notice?
    /// The downloading Mac's answer to the last link you sent.
    private(set) var addReply: (ok: Bool, message: String)?
    /// Its answer to the last button you pressed in the queue.
    private(set) var actionReply: (ok: Bool, message: String)?
    private(set) var sending = false

    var isConnected: Bool { if case .connected = status { return true } else { return false } }

    /// Your pick when more than one downloading Mac is found.
    var chosenName: String? = UserDefaults.standard.string(forKey: DownloaderLink.chosenKey) {
        didSet {
            UserDefaults.standard.set(chosenName, forKey: Self.chosenKey)
            reconsider()
        }
    }

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var endpoints: [String: NWEndpoint] = [:]
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var connectionName: String?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var iso = ISO8601DateFormatter()

    // MARK: Start and stop

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: LinkService.serviceType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let link = DownloaderLink.shared
                    switch state {
                    case .waiting(let error), .failed(let error):
                        link.status = .blocked("This Mac can’t look on your network yet: \(error.localizedDescription)")
                    case .ready:
                        if case .blocked = link.status { link.status = .looking }
                        link.reconsider()
                    default: break
                    }
                }
            }
        }
        browser.browseResultsChangedHandler = { results, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { DownloaderLink.shared.update(results) } }
        }
        status = .looking
        browser.start(queue: .main)
        self.browser = browser
        Notifier.shared.start()
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        browser?.cancel()
        browser = nil
        drop()
        endpoints = [:]
        found = []
        status = .off
    }

    // MARK: Finding the downloading Mac

    private func update(_ results: Set<NWBrowser.Result>) {
        var next: [String: NWEndpoint] = [:]
        for result in results {
            // The same Mac can show up once per network (Wi-Fi and Ethernet); one entry per name is enough.
            if case .service(let name, _, _, _) = result.endpoint, next[name] == nil { next[name] = result.endpoint }
        }
        endpoints = next
        found = next.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        reconsider()
    }

    /// The Mac this one should be talking to: your pick if it's there, else the only one found.
    private var target: String? {
        if let chosenName, endpoints[chosenName] != nil { return chosenName }
        return found.count == 1 ? found.first : nil
    }

    private func reconsider() {
        if case .blocked = status { return }
        guard browser != nil else { return }
        guard let target, let endpoint = endpoints[target] else {
            if connection != nil, connectionName.map({ endpoints[$0] == nil }) ?? true { drop() }
            if connection == nil { status = found.count > 1 ? .choosing : .looking }
            return
        }
        if connectionName == target, connection != nil { return }
        connect(to: target, at: endpoint)
    }

    // MARK: The connection

    private func connect(to name: String, at endpoint: NWEndpoint) {
        drop()
        if macName != name {
            // A different Mac: its queue and folders replace the old one's; the alert history starts over.
            items = []
            folders = []
            destination = nil
            ops = []
            queueAt = nil
            Notifier.shared.forget()
        }
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connectionName = name
        status = .connecting(name)
        connection.stateUpdateHandler = { [weak connection] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let link = DownloaderLink.shared
                    guard let connection, link.connection === connection else { return }
                    switch state {
                    case .ready:
                        link.status = .connected(name)
                        link.send(["op": "watch"])
                    case .waiting, .failed, .cancelled:
                        link.lost()
                    default: break
                    }
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func drop() {
        let old = connection
        connection = nil
        connectionName = nil
        sending = false
        old?.cancel()
    }

    /// The connection broke (the downloading Mac quit, slept or restarted). Try again in a few seconds.
    private func lost() {
        drop()
        status = found.count > 1 && target == nil ? .choosing : .looking
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.reconsider()
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { chunk, _, complete, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let link = DownloaderLink.shared
                    guard link.connection === connection else { return }
                    var buffer = buffer
                    if let chunk { buffer.append(chunk) }
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        link.handle(Data(line))
                    }
                    if complete || error != nil || buffer.count > 16_777_216 {
                        link.lost()
                    } else {
                        link.receive(on: connection, buffer: buffer)
                    }
                }
            }
        }
    }

    private func send(_ message: [String: Any]) {
        guard let connection, var data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: What you do

    /// Sends one or more links. `folder` is a path from the downloading Mac's recent folders, or nil for where it
    /// puts links now.
    func sendLinks(_ text: String, folder: String?) {
        guard isConnected else { return }
        var message: [String: Any] = ["op": "add", "link": text]
        if let folder, ops.contains("add.folder") { message["folder"] = folder }
        addReply = nil
        sending = true
        send(message)
    }

    func cancel(_ item: Item) { act(["op": "cancel", "id": item.id]) }
    func tryAgain(_ item: Item) { act(["op": "retry", "id": item.id]) }
    func cancelRest(of group: String) { act(["op": "cancelRest", "group": group]) }
    func clearFinished() { act(["op": "clearFinished"]) }

    /// True when the downloading Mac can carry out this op right now.
    func can(_ op: String) -> Bool { isConnected && ops.contains(op) }

    private func act(_ message: [String: Any]) {
        guard isConnected, let op = message["op"] as? String, ops.contains(op) else { return }
        actionReply = nil
        send(message)
    }

    // MARK: What the downloading Mac says

    private func handle(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = message["kind"] as? String else { return }
        switch kind {
        case "queue":
            take(message)
        case "added":
            sending = false
            addReply = ((message["ok"] as? Bool) ?? false, (message["message"] as? String) ?? "")
        case "result":
            actionReply = ((message["ok"] as? Bool) ?? false, (message["message"] as? String) ?? "")
        default:
            break
        }
    }

    private func take(_ message: [String: Any]) {
        let name = (message["mac"] as? String) ?? connectionName ?? ""
        let rows = (message["items"] as? [[String: Any]]) ?? []
        let newItems: [Item] = rows.compactMap { row in
            guard let id = row["id"] as? String, let itemName = row["name"] as? String,
                  let state = row["state"] as? String else { return nil }
            return Item(
                id: id, name: itemName, state: state,
                received: (row["received"] as? NSNumber)?.int64Value ?? 0,
                size: (row["size"] as? NSNumber)?.int64Value,
                group: row["group"] as? String,
                folder: (row["folder"] as? String) ?? "",
                note: row["note"] as? String,
                checked: row["checked"] as? String,
                nextTry: (row["nextTry"] as? String).flatMap(iso.date(from:)),
                finished: (row["finished"] as? String).flatMap(iso.date(from:)))
        }
        var newNotice: Notice?
        if let raw = message["notice"] as? [String: Any], let text = raw["text"] as? String,
           let at = (raw["at"] as? String).flatMap(iso.date(from:)) {
            newNotice = Notice(text: text, at: at, from: name)
        }

        Notifier.shared.compare(old: items, new: newItems, notice: newNotice, from: name, firstOfRun: queueAt == nil)

        macName = name
        items = newItems
        queueAt = .now
        ops = Set((message["ops"] as? [String]) ?? ["add", "queue", "watch"])
        folders = ((message["folders"] as? [[String: Any]]) ?? []).compactMap(Self.folder)
        destination = (message["destination"] as? [String: Any]).flatMap(Self.folder)
        // A restart clears the downloading Mac's notice; this Mac keeps the last one it heard (C-034).
        if let newNotice { notice = newNotice }
    }

    private static func folder(_ raw: [String: Any]) -> Folder? {
        guard let path = raw["path"] as? String else { return nil }
        return Folder(path: path, name: (raw["name"] as? String) ?? (path as NSString).lastPathComponent)
    }
}
#endif
