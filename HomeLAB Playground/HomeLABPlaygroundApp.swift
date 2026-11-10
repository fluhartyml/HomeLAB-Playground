//
//  HomeLABPlaygroundApp.swift
//  HomeLAB Playground
//
//  REM: One universal SwiftUI app for iPhone, iPad and Mac. His word 2026-11-05:
//  REM: "i want it to be a universal app and a public repo".
//  REM: The design lives on the amber sheet (Download-Manager-DRAFT-2026-11-05.html, section C);
//  REM: features are built only from lines he has locked there.
//  REM: C-010: "One Mac app, two roles" — on a Mac set to Download, the queue, the network service and the
//  REM: 5 AM restart start at launch, so a reopened or rebooted Mac carries on by itself (C-012).
//

import SwiftUI

@main
struct HomeLABPlaygroundApp: App {
    init() {
        #if os(macOS)
        RoleRunner.apply(AppRole.current)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
