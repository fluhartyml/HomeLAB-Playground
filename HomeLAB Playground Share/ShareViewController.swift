//
//  ShareViewController.swift
//  HomeLAB Playground Share
//
//  Safari's Share menu → HomeLAB Playground.
//

import AppKit
import UniformTypeIdentifiers

// REM  C-004, his word 2026-11-09 19:5x: "yes both." — paste into the app's window, AND Safari's Share menu. This is
// REM  the Share menu half. The paste box was built in HomeLAB Playground 2.
// REM  How it hands off: the extension takes the page's web link and opens homelabplayground://add?link=… . The app
// REM  catches it (ShareInbox) and the link lands in that Mac's paste box, then goes the same way a pasted link goes:
// REM  sent to the downloading Mac on a Mac set to Send links, or into the folder window on a Mac set to Download.
// REM  One path for a link, not two, so the Share menu can never behave differently from the paste box.
// REM  Text 18 pt (his 18 pt minimum rule).
final class ShareViewController: NSViewController {
    private let label = NSTextField(wrappingLabelWithString: "Sending the link to HomeLAB Playground.")

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 90))
        label.font = .systemFont(ofSize: 18)
        label.frame = box.bounds.insetBy(dx: 18, dy: 18)
        label.autoresizingMask = [.width, .height]
        label.setAccessibilityLabel("Share status")
        box.addSubview(label)
        view = box
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        Task {
            if let link = await Self.firstWebLink(in: providers) {
                hand(link)
            } else {
                label.stringValue = "There’s no web link here to send."
                try? await Task.sleep(for: .seconds(2))
                extensionContext?.cancelRequest(withError: NSError(domain: "HomeLAB Playground", code: 1))
            }
        }
    }

    /// Opens the app with the link; the app does the rest.
    private func hand(_ link: URL) {
        var parts = URLComponents()
        parts.scheme = "homelabplayground"
        parts.host = "add"
        parts.queryItems = [URLQueryItem(name: "link", value: link.absoluteString)]
        if let url = parts.url { NSWorkspace.shared.open(url) }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// The first http or https link among what Safari shared.
    // REM  nonisolated on purpose: NSItemProvider calls back on its own thread, never the main one.
    nonisolated private static func firstWebLink(in providers: [NSItemProvider]) async -> URL? {
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { done in
                _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in done.resume(returning: url) }
            }
            if let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { return url }
        }
        return nil
    }
}
