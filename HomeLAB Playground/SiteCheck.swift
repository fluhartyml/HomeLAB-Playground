#if os(macOS)
//
//  SiteCheck.swift
//  HomeLAB Playground
//
//  Before a file downloads: ask the site about it (HEAD), then peek at its first bytes (Range 0-63).
//

import Foundation

// REM  READ WHAT THE SITE SAYS FIRST — his ask with the C lines: before downloading, read what the site says about the
// REM  file (name, size, type, last changed, whether it can resume) and peek at the first bytes to confirm what it is.
// REM  The peek catches the classic trap: a "download" link that hands back a web page instead of the file.
// REM  C-002: "check the checksum when available" — a few sites send one in their headers (Content-MD5, Digest,
// REM  Repr-Digest, x-goog-hash); when they do, it is kept and checked like archive.org's.
nonisolated enum SiteCheck {
    struct Result: Sendable {
        var report: SiteReport
        var md5: String?
        var sha1: String?
        var sha256: String?
    }

    enum Failure: Error, LocalizedError {
        case unreachable(String)
        var errorDescription: String? {
            switch self { case .unreachable(let why): return why }
        }
    }

    static func run(_ url: URL) async throws -> Result {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        var head = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        head.httpMethod = "HEAD"
        var http: HTTPURLResponse?
        do {
            http = try await session.data(for: head).1 as? HTTPURLResponse
        } catch {
            throw Failure.unreachable("The site didn’t answer: \(error.localizedDescription)")
        }

        var report = SiteReport(status: http?.statusCode ?? 0, contentType: http?.mimeType, size: nil,
                                lastModified: http?.value(forHTTPHeaderField: "Last-Modified"),
                                resumable: http?.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true,
                                suggestedName: suggestedName(http), firstBytes: nil, looksLikeWebPage: false)
        if let http, http.expectedContentLength > 0, http.value(forHTTPHeaderField: "Content-Encoding") == nil {
            report.size = http.expectedContentLength
        }
        var result = Result(report: report)
        if let http { readDigests(http, into: &result) }

        // The peek. A site that ignores Range sends the whole file, so only the first 64 bytes are read, then it stops.
        var peek = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        peek.setValue("bytes=0-63", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await session.bytes(for: peek)
            var first: [UInt8] = []
            for try await byte in bytes {
                first.append(byte)
                if first.count >= 64 { break }
            }
            bytes.task.cancel()
            if let peekHTTP = response as? HTTPURLResponse {
                if peekHTTP.statusCode == 206 {
                    result.report.resumable = true
                    if result.report.size == nil, let total = totalFromContentRange(peekHTTP) { result.report.size = total }
                }
                // A site that refused HEAD (405 and the like) still answers the peek — keep the better answer.
                if !(200..<300).contains(result.report.status) { result.report.status = peekHTTP.statusCode }
                if result.report.contentType == nil { result.report.contentType = peekHTTP.mimeType }
                if result.report.suggestedName == nil { result.report.suggestedName = suggestedName(peekHTTP) }
            }
            let kind = sniff(first)
            result.report.firstBytes = kind
            let ext = url.pathExtension.lowercased()
            result.report.looksLikeWebPage = kind == webPage && !["html", "htm", "xhtml", "php", "asp", "aspx"].contains(ext)
        } catch {
            if http == nil { throw Failure.unreachable("The site didn’t answer: \(error.localizedDescription)") }
        }
        return result
    }

    // MARK: Headers

    private static func suggestedName(_ http: HTTPURLResponse?) -> String? {
        guard let http, http.value(forHTTPHeaderField: "Content-Disposition") != nil,
              let name = http.suggestedFilename, !name.isEmpty else { return nil }
        return name
    }

    static func totalFromContentRange(_ http: HTTPURLResponse) -> Int64? {
        guard let range = http.value(forHTTPHeaderField: "Content-Range"),
              let slash = range.lastIndex(of: "/") else { return nil }
        return Int64(range[range.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    private static func readDigests(_ http: HTTPURLResponse, into result: inout Result) {
        if let md5 = http.value(forHTTPHeaderField: "Content-MD5"), let hex = hex(fromBase64: md5) { result.md5 = hex }
        for field in ["Repr-Digest", "Digest", "x-goog-hash"] {
            guard let value = http.value(forHTTPHeaderField: field) else { continue }
            for part in value.split(separator: ",") {
                guard let eq = part.firstIndex(of: "=") else { continue }
                let algorithm = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let encoded = part[part.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " :"))
                guard let hex = hex(fromBase64: encoded) else { continue }
                switch algorithm {
                case "md5": result.md5 = result.md5 ?? hex
                case "sha", "sha1", "sha-1": result.sha1 = result.sha1 ?? hex
                case "sha-256", "sha256": result.sha256 = result.sha256 ?? hex
                default: break
                }
            }
        }
    }

    private static func hex(fromBase64 text: String) -> String? {
        guard let data = Data(base64Encoded: text), !data.isEmpty else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: First bytes

    static let webPage = "a web page"

    /// What the first bytes say the file is.
    static func sniff(_ b: [UInt8]) -> String {
        func at(_ offset: Int, _ text: String) -> Bool {
            let want = Array(text.utf8)
            return b.count >= offset + want.count && Array(b[offset..<offset + want.count]) == want
        }
        func starts(_ bytes: [UInt8]) -> Bool { b.count >= bytes.count && Array(b[0..<bytes.count]) == bytes }

        if b.isEmpty { return "an empty file" }
        if at(4, "ftyp") { return at(8, "qt  ") ? "QuickTime video" : "MPEG-4 video or audio" }
        if starts([0x1A, 0x45, 0xDF, 0xA3]) { return "Matroska or WebM video" }
        if at(0, "RIFF") && at(8, "AVI ") { return "AVI video" }
        if at(0, "RIFF") && at(8, "WAVE") { return "WAV audio" }
        if starts([0x00, 0x00, 0x01, 0xBA]) || starts([0x00, 0x00, 0x01, 0xB3]) { return "MPEG video" }
        if starts([0x30, 0x26, 0xB2, 0x75]) { return "Windows Media video or audio" }
        if at(0, "FLV") { return "Flash video" }
        if at(0, "ID3") || (b.count > 1 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) { return "MP3 audio" }
        if at(0, "fLaC") { return "FLAC audio" }
        if at(0, "OggS") { return "Ogg audio or video" }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return "a ZIP archive" }
        if at(0, "Rar!") { return "a RAR archive" }
        if starts([0x37, 0x7A, 0xBC, 0xAF]) { return "a 7-Zip archive" }
        if starts([0x1F, 0x8B]) { return "a gzip archive" }
        if at(0, "%PDF") { return "a PDF" }
        if starts([0xFF, 0xD8, 0xFF]) { return "a JPEG picture" }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "a PNG picture" }
        if at(0, "GIF8") { return "a GIF picture" }
        if at(0, "koly") || starts([0x78, 0x01, 0x73, 0x0D]) { return "a disk image" }
        let text = String(decoding: b, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("<!doctype html") || text.hasPrefix("<html") || text.hasPrefix("<head") { return webPage }
        if text.hasPrefix("<?xml") { return "an XML file" }
        if text.hasPrefix("{") || text.hasPrefix("[") { return "a JSON file" }
        return "not a type this app recognizes"
    }
}
#endif
