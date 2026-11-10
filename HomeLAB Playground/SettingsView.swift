#if os(macOS)
//
//  SettingsView.swift
//  HomeLAB Playground
//
//  The Mac's Settings: what this Mac does (C-010), and an Access row with an on/off and a button for every permission.
//

import AppKit
import ServiceManagement
import SwiftUI

// REM  His rule: every permission gets an Access button in Settings showing on/off.
// REM  The downloading Mac needs three: the download folder (C-016, kept as a bookmark), Open at Login (C-012, so it
// REM  comes back after the Mac restarts), and the local network (C-011, so the other Mac can find it).
// REM  The sending Mac (C-021) needs two: notifications (C-015, "with a notification") and the local network (C-011,
// REM  to find the downloading Mac). Its "spoken line if you turn that on" (C-015) is the Speak Alerts switch, off
// REM  until you turn it on.
struct SettingsView: View {
    @AppStorage(AppRole.key) private var roleRaw = ""
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 18
    @State private var folderTick = 0
    @AppStorage(Notifier.speakKey) private var speakAlerts = false

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(
                    get: { AppRole(rawValue: roleRaw) ?? .send },
                    set: { RoleRunner.choose($0) }
                )) {
                    ForEach(AppRole.allCases, id: \.self) { role in
                        Text(role.title).font(.system(size: bodySize)).tag(role)
                    }
                } label: {
                    Text("This Mac").font(.system(size: bodySize))
                }
                .pickerStyle(.radioGroup)
                .accessibilityLabel("This Mac's role")
                Text(AppRole(rawValue: roleRaw)?.explanation ?? "Choose what this Mac does. You set it once on each Mac.")
                    .font(.system(size: bodySize))
                    .foregroundStyle(.secondary)
            } header: {
                Text("What This Mac Does").font(.system(size: bodySize, weight: .semibold))
            }

            if AppRole(rawValue: roleRaw) == .download {
                Section {
                    folderRow
                    loginRow
                    networkRow
                } header: {
                    Text("Access").font(.system(size: bodySize, weight: .semibold))
                }
            }

            if AppRole(rawValue: roleRaw) == .send {
                Section {
                    Toggle(isOn: $speakAlerts) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Speak alerts out loud").font(.system(size: bodySize))
                            Text("When a download finishes or stalls, or the downloading Mac sends a notice, this Mac also says it out loud.")
                                .font(.system(size: bodySize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Speak alerts")
                } header: {
                    Text("Alerts").font(.system(size: bodySize, weight: .semibold))
                }
                Section {
                    notificationsRow
                    senderNetworkRow
                } header: {
                    Text("Access").font(.system(size: bodySize, weight: .semibold))
                }
            }

            Section {
                Text("Build \(BuildStamp.buildNumber) · \(BuildStamp.commit)")
                    .font(.system(size: bodySize))
                    .accessibilityLabel("Build \(BuildStamp.buildNumber)")
                Text("This app uses no third-party code.")
                    .font(.system(size: bodySize))
            } header: {
                Text("About").font(.system(size: bodySize, weight: .semibold))
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 520)
        .onAppear { LoginItem.shared.refresh() }
        .task { await Notifier.shared.refresh() }
    }

    private var folderRow: some View {
        _ = folderTick
        let folder = FolderAccess.lastFolder
        let on = folder.map { FolderAccess.isWritable($0.url) } ?? false
        return AccessRow(
            title: "Download folder",
            isOn: on,
            detail: folder.map { on ? "Writing to \($0.url.path)." : "Can’t reach \($0.url.path). Connect its drive or choose it again." }
                ?? "No folder chosen yet. You give permission once and this Mac keeps it.",
            button: "Choose Folder",
            buttonLabel: "Choose folder"
        ) {
            FolderAccess.choose(message: "Choose the folder this Mac downloads into, then press Open.") { _ in folderTick += 1 }
        }
    }

    private var loginRow: some View {
        let login = LoginItem.shared
        let detail: String
        switch login.status {
        case .enabled: detail = "This app opens by itself after this Mac restarts, and picks up its downloads."
        case .requiresApproval: detail = "Waiting for your OK in System Settings ▸ General ▸ Login Items."
        default: detail = login.problem ?? "Off. After this Mac restarts, downloads wait until you open the app."
        }
        return AccessRow(
            title: "Open at login",
            isOn: login.isOn,
            detail: detail,
            button: login.isOn ? "Turn Off" : (login.status == .requiresApproval ? "Open Login Items" : "Turn On"),
            buttonLabel: "Open at login"
        ) {
            if login.isOn {
                login.turnOff()
            } else if login.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                login.turnOn()
            }
        }
    }

    private var notificationsRow: some View {
        let notifier = Notifier.shared
        let detail: String
        switch notifier.access {
        case .on: detail = "You get an alert when a download finishes or stalls, and when the downloading Mac sends a notice."
        case .notAsked: detail = "Off. Turn it on to get an alert when a download finishes or stalls."
        case .off, .unknown: detail = "Off. Turn on HomeLAB Playground in System Settings ▸ Notifications."
        }
        return AccessRow(
            title: "Notifications",
            isOn: notifier.access == .on,
            detail: detail,
            button: notifier.access == .notAsked ? "Turn On" : "Open Notification Settings",
            buttonLabel: "Notifications"
        ) {
            if notifier.access == .notAsked {
                Task { await notifier.ask() }
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var senderNetworkRow: some View {
        let link = DownloaderLink.shared
        let blocked: String? = { if case .blocked(let why) = link.status { return why } else { return nil } }()
        let on = link.status != .off && blocked == nil
        let detail: String
        if let blocked {
            detail = "\(blocked) Turn on HomeLAB Playground in Privacy & Security ▸ Local Network."
        } else if !on {
            detail = "Off."
        } else if link.found.isEmpty {
            detail = "This Mac can look on your network. No Mac set to Download has turned up yet."
        } else {
            detail = "This Mac can look on your network and finds \(link.found.count == 1 ? "1 Mac" : "\(link.found.count) Macs") set to Download."
        }
        return AccessRow(
            title: "Local network",
            isOn: on,
            detail: detail,
            button: "Open Privacy Settings",
            buttonLabel: "Network privacy"
        ) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var networkRow: some View {
        let service = LinkService.shared
        let on = service.status == .advertising
        let detail: String
        switch service.status {
        case .advertising: detail = "Other Macs on your network can find this Mac and send it links."
        case .blocked(let why): detail = "\(why) Turn on HomeLAB Playground in Privacy & Security ▸ Local Network."
        case .starting: detail = "Announcing this Mac on your network."
        case .off: detail = "Off."
        }
        return AccessRow(
            title: "Local network",
            isOn: on,
            detail: detail,
            button: "Open Privacy Settings",
            buttonLabel: "Network privacy"
        ) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

private struct AccessRow: View {
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 18
    let title: String
    let isOn: Bool
    let detail: String
    let button: String
    let buttonLabel: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: bodySize, weight: .semibold))
                Text(isOn ? "On" : "Off")
                    .font(.system(size: bodySize, weight: .bold))
                    .foregroundStyle(isOn ? .green : .orange)
                    .accessibilityLabel(isOn ? "On" : "Off")
                Spacer()
                Button(action: action) {
                    Text(button).font(.system(size: bodySize))
                }
                .accessibilityLabel(buttonLabel)
            }
            Text(detail)
                .font(.system(size: bodySize))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
#endif
