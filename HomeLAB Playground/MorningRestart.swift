#if os(macOS)
//
//  MorningRestart.swift
//  HomeLAB Playground
//
//  At 5 AM the downloading Mac pauses its file, tells the other Macs, quits and reopens itself; reopening checks the drives.
//

import AppKit
import Foundation
import StoreKit

// REM  C-033, locked 2026-11-09: "Same pattern as Mediaworks build 242 (your 'update or recycle lab b at 5 in the
// REM  morning', Nov 3, 21:47): at 5:00 AM, once the file in progress is safely paused, the app quits and reopens
// REM  itself. Reopening runs the 030 check and picks up any update waiting in TestFlight. Downloads resume on their
// REM  own, so nothing is lost."
// REM  Pattern taken from Lyceum Mediaworks' MorningRestart.swift: the new copy is opened BEFORE the old one quits
// REM  (never quit into nothing), and the new copy waits for the old one to finish quitting.
// REM  NOTE — Mediaworks later (2026-11-08) moved to "check first, restart only if needed" for ITS Apple TV deletes.
// REM  This sheet's C-033 says every morning, so this restarts every morning. Say the word to change it.
// REM  C-032: "If it's running from TestFlight, it updates itself when you haven't already." A copy installed by
// REM  TestFlight quits with a small timer outside the app that reopens it in 5 minutes — TestFlight gets the gap it
// REM  needs to install (Mediaworks' quitForUpdate). Not yet proven on Mediaworks either (the sheet says so).
// REM  C-034: before it goes, every watching Mac gets "… restarting for its 5 AM check …"; after, "… is back up."
// REM  Tries each minute from 5:00 to 7:00, once a day. A missed morning is fine.
@MainActor
enum MorningRestart {
    private static let lastDayKey = "morningRestartLastDay"
    private static let backUpKey = "morningRestartAnnounceBackUp"
    private static let lastRestartKey = "morningRestartLastAt"
    private static let waitArgument = "-homelabWaitForPID"
    private static var started = false
    private static var going = false
    /// Seconds a TestFlight copy stays closed so TestFlight can install an update.
    static let updateWait = 300

    static var lastRestartAt: Date? { UserDefaults.standard.object(forKey: lastRestartKey) as? Date }

    /// Call once at launch on the downloading Mac.
    static func start() {
        guard !started else { return }
        started = true
        waitForPreviousCopy()
        Task { @MainActor in
            // C-033: "Reopening runs the 030 check" — and it is harmless on any other launch too.
            DriveCheck.run()
            await learnWhereInstalledFrom()
            if UserDefaults.standard.bool(forKey: backUpKey) {
                UserDefaults.standard.set(false, forKey: backUpKey)
                try? await Task.sleep(for: .seconds(5))
                LinkService.shared.announce("\(LinkService.macName) is back up after its 5 AM check. Downloads go on where they stopped.")
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await check()
            }
        }
    }

    private static func check() async {
        guard AppRole.current == .download, !going else { return }
        let now = Date.now
        let hour = Calendar.current.component(.hour, from: now)
        guard hour >= 5, hour < 7 else { return }
        let today = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
        guard UserDefaults.standard.string(forKey: lastDayKey) != today else { return }
        going = true
        // Written BEFORE the restart, so the reopened copy doesn't restart again the same morning.
        UserDefaults.standard.set(today, forKey: lastDayKey)
        UserDefaults.standard.set(now, forKey: lastRestartKey)
        let forUpdate = installedByTestFlight
        let back = forUpdate ? "about 5 minutes" : "about a minute"
        LinkService.shared.announce("\(LinkService.macName) is restarting for its 5 AM check, back in \(back).")
        await DownloadQueue.shared.pauseForRestart()
        UserDefaults.standard.set(true, forKey: backUpKey)
        try? await Task.sleep(for: .seconds(3))       // lets the notice reach the watching Macs
        if forUpdate { quitForUpdate() } else { relaunch() }
    }

    /// True when this copy was installed by TestFlight (StoreKit says its environment is the sandbox). A copy built
    /// in Xcode is not, so it takes the ordinary quick restart. Read once at launch and kept, so the 5 AM restart never
    /// waits on the App Store.
    private static var installedByTestFlight = false

    private static func learnWhereInstalledFrom() async {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TestFlight") != nil,
              let result = try? await AppTransaction.shared else { return }
        switch result {
        case .verified(let transaction), .unverified(let transaction, _):
            installedByTestFlight = transaction.environment == .sandbox
        }
    }

    private static func quitForUpdate() {
        if let testFlight = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TestFlight") {
            let quiet = NSWorkspace.OpenConfiguration()
            quiet.activates = false
            NSWorkspace.shared.openApplication(at: testFlight, configuration: quiet) { _, _ in }
        }
        let timer = Process()
        timer.executableURL = URL(fileURLWithPath: "/bin/sh")
        let bundle = Bundle.main.bundleIdentifier ?? "com.homelab.playground"
        timer.arguments = ["-c", "sleep \(updateWait); /usr/bin/open -g -b \(bundle)"]
        do {
            try timer.run()
        } catch {
            relaunch()          // never quit into nothing
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard timer.isRunning else { relaunch(); return }
            NSApp.terminate(nil)
        }
    }

    private static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = [waitArgument, String(ProcessInfo.processInfo.processIdentifier)]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                // If the new copy did not start, this one keeps running and downloading — never quit into nothing.
                guard app != nil, error == nil else {
                    MainActor.assumeIsolated {
                        going = false
                        UserDefaults.standard.set(false, forKey: backUpKey)
                        DownloadQueue.shared.start()
                    }
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// The reopened copy waits (up to 20 seconds) for the old one to quit, so two copies never write one file.
    private static func waitForPreviousCopy() {
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of: waitArgument), at + 1 < args.count, let pid = pid_t(args[at + 1]) else { return }
        let end = Date.now.addingTimeInterval(20)
        while kill(pid, 0) == 0, Date.now < end { usleep(100_000) }
    }
}

// REM  C-030 / C-031, his word 2026-11-05: "Around 5 AM every morning it goes into a refresh mode that refreshes every
// REM  attached external drive and network drive, to keep downtime at zero." / "Refresh means a check: Lab B looks
// REM  again to see that everything is working as intended. It only reconnects something, such as a network share,
// REM  when that's needed. Nothing that's working gets touched."
// REM  So: every external and network drive is asked for its size (asking touches nothing). Every download folder in the
// REM  queue is looked at; one that can't be reached is re-opened from its saved bookmark, which reconnects a network
// REM  share that dropped. Nothing that answers is touched. The result is shown in the window.
@MainActor
@Observable
final class DriveCheck {
    static let shared = DriveCheck()
    private(set) var lastRun: Date?
    private(set) var summary: String?

    static func run() { shared.perform() }

    private func perform() {
        var drives = 0
        var silent: [String] = []
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)), values.volumeIsRootFileSystem != true,
                  values.volumeIsInternal != true || values.volumeIsLocal == false else { continue }
            drives += 1
            if (try? volume.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity == nil {
                silent.append(values.volumeName ?? volume.lastPathComponent)
            }
        }

        var folders = 0
        var reconnected: [String] = []
        var unreachable: [String] = []
        var seen = Set<Data>()
        let bookmarks = DownloadQueue.shared.items.filter { !$0.isFinished }.map { ($0.folderBookmark, $0.folderName) }
        for (bookmark, name) in bookmarks where seen.insert(bookmark).inserted {
            folders += 1
            if let url = FolderAccess.resolve(bookmark, mount: false)?.0, FolderAccess.isWritable(url) {
                continue        // working — not touched
            }
            // Not answering: resolving the bookmark once more mounts a network share that dropped.
            if let url = FolderAccess.resolve(bookmark)?.0, FolderAccess.isWritable(url) {
                reconnected.append(name)
            } else {
                unreachable.append(name)
            }
        }

        var lines: [String] = []
        lines.append(drives == 1 ? "1 external or network drive" : "\(drives) external or network drives")
        lines[0] += silent.isEmpty ? " answered." : "; not answering: \(ListFormatter.localizedString(byJoining: silent))."
        if folders > 0 {
            if reconnected.isEmpty && unreachable.isEmpty {
                lines.append(folders == 1 ? "The download folder is ready." : "All \(folders) download folders are ready.")
            }
            if !reconnected.isEmpty { lines.append("Reconnected: \(ListFormatter.localizedString(byJoining: reconnected)).") }
            if !unreachable.isEmpty {
                lines.append("Can’t reach: \(ListFormatter.localizedString(byJoining: unreachable)). Downloads there wait until it’s back.")
            }
        }
        summary = lines.joined(separator: " ")
        lastRun = .now
    }
}
#endif
