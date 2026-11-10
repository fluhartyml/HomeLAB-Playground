#if os(macOS)
//
//  AppRole.swift
//  HomeLAB Playground
//
//  What this Mac does: sends links, or downloads them. Set once per Mac.
//

import Foundation
import Observation
import ServiceManagement

// REM  C-010, his word 2026-11-09: "isnt it obvious?" — "One Mac app, two roles. On the MacBook it sends links. On
// REM  Lab B it downloads them. You set the role once on each Mac." The first window asks; Settings can change it.
// REM  The names in his lines (MacBook, Lab B) never appear in the app — it ships to anyone, so it says "this Mac".
nonisolated enum AppRole: String, CaseIterable, Sendable {
    case send, download

    static let key = "appRole"

    static var current: AppRole? {
        UserDefaults.standard.string(forKey: key).flatMap(AppRole.init(rawValue:))
    }

    var title: String {
        switch self {
        case .send: return "Send links"
        case .download: return "Download"
        }
    }

    var explanation: String {
        switch self {
        case .send: return "This Mac sends download links to the Mac that downloads them."
        case .download: return "This Mac downloads the links you give it and keeps at it until every file is whole."
        }
    }
}

@MainActor
enum RoleRunner {
    /// Starts or stops the downloading side to match this Mac's role.
    static func apply(_ role: AppRole?) {
        if role == .download {
            DownloadQueue.shared.start()
            LinkService.shared.start()
            MorningRestart.start()
        } else {
            DownloadQueue.shared.stop()
            LinkService.shared.stop()
        }
    }

    static func choose(_ role: AppRole) {
        let before = AppRole.current
        UserDefaults.standard.set(role.rawValue, forKey: AppRole.key)
        // REM  C-012: "starts again on its own after Lab B restarts" — choosing Download turns on Open at Login once.
        // REM  Settings shows it and can turn it off.
        if role == .download, before != .download { LoginItem.shared.turnOn() }
        apply(role)
    }
}

/// Open at Login — so the downloading Mac picks up its queue by itself after a restart (C-012).
@MainActor
@Observable
final class LoginItem {
    static let shared = LoginItem()
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var problem: String?

    var isOn: Bool { status == .enabled }

    func refresh() { status = SMAppService.mainApp.status }

    func turnOn() {
        do {
            try SMAppService.mainApp.register()
            problem = nil
        } catch {
            problem = "macOS didn’t accept it: \(error.localizedDescription)"
        }
        refresh()
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func turnOff() {
        do {
            try SMAppService.mainApp.unregister()
            problem = nil
        } catch {
            problem = "macOS didn’t accept it: \(error.localizedDescription)"
        }
        refresh()
    }
}
#endif
