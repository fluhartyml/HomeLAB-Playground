#if os(macOS)
//
//  FolderAccess.swift
//  HomeLAB Playground
//
//  The folder picker (C-005) and the kept permission to write there (C-016).
//

import AppKit
import Foundation

// REM  C-005, his word 2026-11-09: "it opens a finder in the last download folder but you can navigate to another
// REM  folder to press open." So: a Finder folder window (NSOpenPanel, folders only) that opens AT the last folder you
// REM  picked; you can go anywhere else, then press Open. The pick is remembered as the next starting place.
// REM  C-016: "Lab B asks once for permission to write to the external drive, then keeps it. That's the block we hit
// REM  today." The pick is saved as a security-scoped bookmark — every queued file carries its folder's bookmark — so
// REM  after a quit, a 5 AM restart or a reboot the app writes there again without asking.
@MainActor
enum FolderAccess {
    private static let lastFolderKey = "lastDownloadFolderBookmark"
    /// Folders this copy of the app is already holding permission for, by path.
    private static var open: [String: URL] = [:]

    struct Pick {
        var bookmark: Data
        var url: URL
    }

    /// The last folder you picked, with permission held — nil before your first pick.
    static var lastFolder: Pick? {
        guard let data = UserDefaults.standard.data(forKey: lastFolderKey),
              let resolved = resolve(data) else { return nil }
        if resolved.1 != data { UserDefaults.standard.set(resolved.1, forKey: lastFolderKey) }
        return Pick(bookmark: resolved.1, url: resolved.0)
    }

    /// Opens the folder window at the last folder; calls back with your pick, or nil if you cancel.
    static func choose(message: String, then done: @escaping (Pick?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Open"
        // REM  "it opens a finder in the last download folder" — C-005.
        if let last = lastFolder { panel.directoryURL = last.url }
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            else { done(nil); return }
            UserDefaults.standard.set(bookmark, forKey: lastFolderKey)
            hold(url)
            done(Pick(bookmark: bookmark, url: url))
        }
    }

    /// Resolves a saved folder and holds permission to write in it. Returns the bookmark to keep (renewed if stale).
    /// Resolving can reconnect a network share that dropped (C-031: reconnect only when needed).
    /// `mount: false` only looks — it never reconnects anything (the morning check's first look).
    static func resolve(_ bookmark: Data, mount: Bool = true) -> (URL, Data)? {
        var stale = false
        var options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        if !mount { options.insert(.withoutMounting) }
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: options,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        hold(url)
        var keep = bookmark
        if stale, let renewed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            keep = renewed
        }
        return (url, keep)
    }

    private static func hold(_ url: URL) {
        guard open[url.path] == nil else { return }
        if url.startAccessingSecurityScopedResource() { open[url.path] = url }
    }

    /// True when the folder is there and this Mac can write in it.
    static func isWritable(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
    }
}
#endif
