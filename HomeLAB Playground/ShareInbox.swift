#if os(macOS)
//
//  ShareInbox.swift
//  HomeLAB Playground
//
//  Where a link from Safari's Share menu waits until this Mac's window takes it.
//

import Foundation
import Observation

// REM  C-004: the Share extension opens homelabplayground://add?link=… . The link waits here until the window for
// REM  this Mac's role takes it into its paste box (SenderView / DownloaderView). If no role is picked yet, it waits
// REM  until one is. Anything that isn't an http(s) link is dropped, the same test the paste box uses.
@MainActor
@Observable
final class ShareInbox {
    static let shared = ShareInbox()
    static let scheme = "homelabplayground"

    private(set) var pending: String?

    func receive(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host() == "add",
              let link = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "link" })?.value,
              !DownloadQueue.links(in: link).isEmpty else { return }
        pending = [pending, link].compactMap { $0 }.joined(separator: "\n")
    }

    /// Hands over the waiting links, once.
    func take() -> String? {
        defer { pending = nil }
        return pending
    }
}
#endif
