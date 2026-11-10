#if os(macOS)
//
//  Notifier.swift
//  HomeLAB Playground
//
//  The sending Mac tells you when a download stalls or finishes, and passes on the downloading Mac's notices.
//

import AVFoundation
import Foundation
import Observation
import UserNotifications

// REM  C-015, locked 2026-11-09 20:0x: "It tells the MacBook when something stalls or finishes, with a notification,
// REM  plus a spoken line if you turn that on." The spoken line is off until you turn it on in Settings.
// REM  VOICE: AVSpeechSynthesizer with no voice set, so it speaks in the system's own default voice. No voice is ever
// REM  picked by name.
// REM  WHAT COUNTS (Claude's calls, the sheet doesn't say):
// REM    • finishes — a file that was on the list and not done is now done. When that was the last file of an
// REM      archive.org item, the one alert says the whole item is done instead.
// REM    • stalls  — a file goes from working to "waiting to try again" (the site went quiet or offline). One alert per
// REM      file, then quiet for that file for 10 minutes, so a site that is down for hours doesn't buzz all night.
// REM    • notices — C-034's "restarting … back in about a minute" and "back up" get an alert too ("Every HomeLAB
// REM      playground on the network gets the message"). A notice older than 10 minutes when this Mac first hears it
// REM      is shown in the window only.
// REM  The first queue this Mac hears after it opens is only read, never alerted on, so opening the app doesn't
// REM  replay a night of finished files.
@MainActor
@Observable
final class Notifier {
    static let shared = Notifier()
    static let speakKey = "speakAlerts"

    enum Access: Equatable { case unknown, notAsked, on, off }

    private(set) var access: Access = .unknown

    @ObservationIgnored private var started = false
    @ObservationIgnored private var stallToldAt: [String: Date] = [:]
    @ObservationIgnored private var lastNoticeAt: Date?
    @ObservationIgnored private let presenter = NotificationPresenter()
    @ObservationIgnored private let speaker = AVSpeechSynthesizer()

    static let stallQuiet: TimeInterval = 600
    static let staleNotice: TimeInterval = 600

    var speaks: Bool { UserDefaults.standard.bool(forKey: Self.speakKey) }

    /// Called when this Mac starts sending links: shows alerts even while the app is in front, and asks once.
    func start() {
        guard !started else { return }
        started = true
        UNUserNotificationCenter.current().delegate = presenter
        Task {
            await refresh()
            if access == .notAsked { await ask() }
        }
    }

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: access = .on
        case .denied: access = .off
        case .notDetermined: access = .notAsked
        default: access = .off
        }
    }

    func ask() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refresh()
    }

    /// A different downloading Mac: what was alerted about the old one no longer applies.
    func forget() {
        stallToldAt = [:]
        lastNoticeAt = nil
    }

    // MARK: Spotting what changed

    func compare(old: [DownloaderLink.Item], new: [DownloaderLink.Item], notice: DownloaderLink.Notice?,
                 from mac: String, firstOfRun: Bool) {
        if let notice, notice.at != lastNoticeAt {
            lastNoticeAt = notice.at
            if !firstOfRun || Date.now.timeIntervalSince(notice.at) < Self.staleNotice {
                post(title: "Notice from \(mac)", body: notice.text)
            }
        }
        guard !firstOfRun else { return }

        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var groupsToldDone = Set<String>()
        for item in new {
            guard let was = before[item.id] else { continue }
            if item.isDone, !was.isDone {
                stallToldAt[item.id] = nil
                if let group = item.group {
                    let members = new.filter { $0.group == group }
                    let wasAll = old.filter { $0.group == group }.allSatisfy(\.isDone)
                    if members.allSatisfy(\.isDone), !wasAll {
                        if groupsToldDone.insert(group).inserted {
                            post(title: "Download finished",
                                 body: "All \(members.count) files of “\(group)” are done on \(mac) and checked.")
                        }
                        continue
                    }
                }
                post(title: "Download finished", body: "“\(item.name)” is done on \(mac) and checked.")
            } else if item.state == "retrying", was.state != "retrying" {
                if let told = stallToldAt[item.id], Date.now.timeIntervalSince(told) < Self.stallQuiet { continue }
                stallToldAt[item.id] = .now
                let why = item.note.map { " \($0)" } ?? ""
                post(title: "Download stalled",
                     body: "“\(item.name)” stalled on \(mac).\(why) It tries again by itself.")
            }
        }
    }

    // MARK: Telling you

    private func post(title: String, body: String) {
        if speaks {
            // REM  C-015 "plus a spoken line if you turn that on" — default system voice, no voice chosen by name.
            speaker.speak(AVSpeechUtterance(string: "\(title). \(body)"))
        }
        guard access == .on else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

/// Lets alerts show as banners while the app is in front too (macOS hides them otherwise).
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
#endif
