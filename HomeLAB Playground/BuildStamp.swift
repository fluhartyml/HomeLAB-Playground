//
//  BuildStamp.swift
//  HomeLAB Playground
//
//  ⚠️ THE VALUES BELOW ARE REWRITTEN BY `Scripts/stamp-build.sh`. Do not hand-edit them.
//  Every build carries CURRENT_PROJECT_VERSION = git rev-list --count HEAD, and the app shows it.
//

import Foundation

enum BuildStamp {
    /// Short SHA of HEAD when this build was stamped. "+" suffix = uncommitted changes.
    static let commit = "cdbb9a5"

    /// Branch HEAD was on when this build was stamped.
    static let branch = "development"

    /// Local time the stamp was generated — effectively the build time.
    static let built = "2026-11-09 21:11"

    /// CFBundleVersion — set from the commit count by the post-commit hook.
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}
