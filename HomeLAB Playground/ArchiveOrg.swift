#if os(macOS)
//
//  ArchiveOrg.swift
//  HomeLAB Playground
//
//  Turns an archive.org link into the item's own files, each with the size, MD5 and SHA-1 archive.org lists.
//

import Foundation

// REM  C-003, his word 2026-11-09: "yes separate files." The metadata API (https://archive.org/metadata/<identifier>)
// REM  lists every file in an item with its size, format, md5 and sha1 — so each episode downloads on its own and is
// REM  proven whole on its own (C-013), and a dropped connection only costs the one file in progress.
// REM  WHICH FILES (Claude's call, the sheet doesn't say): the files the uploader put there ("original"), not the
// REM  copies archive.org makes for its player ("derivative"), and not archive.org's own bookkeeping (its _meta.xml,
// REM  _files.xml, torrent and thumbnail). A link to one file (…/download/<id>/<file>) gets just that file.
nonisolated enum ArchiveOrg {
    struct Link: Sendable, Equatable {
        var identifier: String
        /// The one file the link names, or nil for the whole item.
        var file: String?
    }

    struct File: Sendable {
        var name: String
        var size: Int64?
        var md5: String?
        var sha1: String?
        var url: URL
    }

    struct Listing: Sendable {
        var title: String
        var files: [File]
    }

    enum Failure: Error, LocalizedError {
        case unreachable(String), noSuchItem, nothingToDownload, noSuchFile(String)
        var errorDescription: String? {
            switch self {
            case .unreachable(let why): return "archive.org didn’t answer: \(why)"
            case .noSuchItem: return "archive.org has no item at that link. Check the link."
            case .nothingToDownload: return "archive.org lists no files you can download in this item."
            case .noSuchFile(let name): return "archive.org doesn’t list \(name) in this item."
            }
        }
    }

    /// archive.org/details/<id>, archive.org/download/<id>[/<file>] — nil for any other link.
    static func parse(_ url: URL) -> Link? {
        guard let host = url.host()?.lowercased(), host == "archive.org" || host.hasSuffix(".archive.org") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "details" || parts[0] == "download" else { return nil }
        let identifier = parts[1]
        let rest = parts.dropFirst(2).joined(separator: "/")
        return Link(identifier: identifier, file: rest.isEmpty ? nil : rest)
    }

    static func listing(for link: Link) async throws -> Listing {
        guard let api = URL(string: "https://archive.org/metadata/\(escape(link.identifier))") else { throw Failure.noSuchItem }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData,
                                                                                timeoutInterval: 60))
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.unreachable("it answered \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreachable("its answer wasn’t readable")
        }
        // An item that doesn't exist comes back as an empty object.
        guard let rawFiles = root["files"] as? [[String: Any]] else { throw Failure.noSuchItem }
        let metadata = root["metadata"] as? [String: Any]
        let title = (metadata?["title"] as? String) ?? (metadata?["title"] as? [String])?.first ?? link.identifier

        var files: [File] = []
        for raw in rawFiles {
            guard let name = raw["name"] as? String else { continue }
            let source = raw["source"] as? String
            let format = (raw["format"] as? String) ?? ""
            if let only = link.file {
                guard name == only || name == only.removingPercentEncoding else { continue }
            } else {
                guard source == "original", !name.hasPrefix("__ia_"), format != "Metadata",
                      !format.contains("BitTorrent"), format != "Item Tile" else { continue }
            }
            let size: Int64? = (raw["size"] as? String).flatMap { Int64($0) } ?? (raw["size"] as? NSNumber)?.int64Value
            let path = name.split(separator: "/", omittingEmptySubsequences: false).map { escape(String($0)) }.joined(separator: "/")
            guard let url = URL(string: "https://archive.org/download/\(escape(link.identifier))/\(path)") else { continue }
            files.append(File(name: name, size: size, md5: (raw["md5"] as? String)?.lowercased(),
                              sha1: (raw["sha1"] as? String)?.lowercased(), url: url))
        }
        if files.isEmpty {
            if let only = link.file { throw Failure.noSuchFile(only) }
            throw Failure.nothingToDownload
        }
        files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Listing(title: title, files: files)
    }

    private static func escape(_ part: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        return part.addingPercentEncoding(withAllowedCharacters: allowed) ?? part
    }
}
#endif
