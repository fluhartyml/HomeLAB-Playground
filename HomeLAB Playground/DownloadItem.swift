#if os(macOS)
//
//  DownloadItem.swift
//  HomeLAB Playground
//
//  One line of the download queue: a file, or an archive.org item still waiting to be listed.
//

import Foundation

// REM  WHY TWO KINDS — C-003, his word 2026-11-09: "yes separate files." An archive.org item is never fetched as one
// REM  zip. It enters the queue as one `.archiveItem` line, and as soon as archive.org lists its files that line is
// REM  replaced by one `.file` line per file. If archive.org is down when the link arrives ("like today", C-012), the
// REM  item line waits and retries like any other download, so a link is never lost.
nonisolated struct DownloadItem: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case file, archiveItem }

    enum State: String, Codable, Sendable {
        case waiting, checking, downloading, verifying, retrying, done
    }

    var id = UUID()
    var kind: Kind
    /// Where the bytes come from. For an archive item, the link that was pasted.
    var link: URL
    /// File: its path inside the destination (may hold subfolders). Archive item: the archive.org identifier.
    var name: String
    /// Archive item only: the one file the link named (…/download/<id>/<file>), or nil for the whole item.
    var onlyFile: String?
    /// The subfolder this file goes in (an archive.org item's title), or nil to go straight into the folder.
    var group: String?
    /// C-016: the security-scoped bookmark for the folder you chose, so a relaunch keeps permission.
    var folderBookmark: Data
    var folderName: String
    /// True once the name is final (an archive.org listing, or the site's own file name has been read).
    var nameSettled = false

    // C-002 / C-013: what the file must match before it counts as done.
    var expectedSize: Int64?
    var md5: String?
    var sha1: String?
    var sha256: String?

    var received: Int64 = 0
    var state: State = .waiting
    /// The last thing that went wrong, in plain words — shown under the file.
    var note: String?
    /// What the site said before any download (HEAD + the first bytes).
    var site: SiteReport?
    var failures = 0
    var nextTry: Date?
    var added = Date.now
    var finished: Date?
    /// "size and MD5", "size" … — what this file was checked against.
    var checkedWith: String?

    var displayName: String {
        switch kind {
        case .file: return (name as NSString).lastPathComponent
        case .archiveItem: return onlyFile.map { ($0 as NSString).lastPathComponent } ?? name
        }
    }

    var isFinished: Bool { state == .done }
}

/// What a site says about a file before it is downloaded — his ask on the sheet: read what the site says first.
nonisolated struct SiteReport: Codable, Sendable, Equatable {
    var status: Int
    var contentType: String?
    var size: Int64?
    var lastModified: String?
    var resumable: Bool
    var suggestedName: String?
    /// What the first bytes say the file is ("MPEG-4 video", "web page" …).
    var firstBytes: String?
    var looksLikeWebPage: Bool
}
#endif
