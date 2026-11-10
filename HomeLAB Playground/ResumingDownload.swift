#if os(macOS)
//
//  ResumingDownload.swift
//  HomeLAB Playground
//
//  Streams one file onto the end of its ".part" file, asking the site only for the bytes not already there.
//

import CryptoKit
import Foundation

// REM  C-012: "It resumes a half-finished file where it stopped." The half-finished file on the drive IS the progress:
// REM  whatever is already in <name>.part is never asked for again (HTTP Range: bytes=<what's there>-). That survives
// REM  a dropped connection, a quit, a crash and a power cut alike — no saved state to lose, just the bytes on disk.
// REM  A site that ignores Range and sends the whole file again is caught (200 instead of 206) and the .part starts over.
nonisolated final class ResumingDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome: Sendable {
        /// The site finished sending. `total` is the full size when the site said it.
        case complete(total: Int64?)
        /// The site has nothing past what's already here (416) — the .part may already be whole.
        case nothingMore(total: Int64?)
        case failed(String)
    }

    private let part: URL
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var handle: FileHandle?
    private var have: Int64 = 0
    private var total: Int64?
    private var verdict: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var task: URLSessionDataTask?
    private var lastReport = Date.distantPast

    init(part: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.part = part
        self.progress = progress
    }

    func run(from source: URL) async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Outcome, Never>) in
                continuation = done
                let files = FileManager.default
                if !files.fileExists(atPath: part.path) { files.createFile(atPath: part.path, contents: nil) }
                guard let handle = try? FileHandle(forWritingTo: part) else {
                    finish(.failed("This Mac can’t write in the download folder."))
                    return
                }
                self.handle = handle
                have = Int64((try? handle.seekToEnd()) ?? 0)

                var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
                if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
                let configuration = URLSessionConfiguration.default
                configuration.urlCache = nil
                configuration.timeoutIntervalForRequest = 60
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                lock.withLock { self.task = task }
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            lock.withLock { task }?.cancel()
        }
    }

    private func finish(_ outcome: Outcome) {
        try? handle?.close()
        handle = nil
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    // Keep asking for the same bytes when the site sends the request on to another server (archive.org does).
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") { next.setValue(range, forHTTPHeaderField: "Range") }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
        switch http.statusCode {
        case 206:
            total = SiteCheck.totalFromContentRange(http)
            // The site must start where the .part ends; anything else and the .part starts over.
            if let range = http.value(forHTTPHeaderField: "Content-Range"),
               let first = range.split(separator: " ").last?.split(separator: "-").first, Int64(first) != have {
                try? handle?.truncate(atOffset: 0)
                have = 0
                verdict = .failed("The site sent the wrong part of the file, so it starts over.")
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        case 200..<300:
            if have > 0 {
                try? handle?.truncate(atOffset: 0)
                have = 0
            }
            total = http.expectedContentLength > 0 && http.value(forHTTPHeaderField: "Content-Encoding") == nil
                ? http.expectedContentLength : nil
            completionHandler(.allow)
        case 416:
            verdict = .nothingMore(total: SiteCheck.totalFromContentRange(http))
            completionHandler(.cancel)
        default:
            verdict = .failed("The site answered \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode)).")
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            verdict = .failed("This Mac couldn’t write to the drive: \(error.localizedDescription)")
            dataTask.cancel()
            return
        }
        have += Int64(data.count)
        let now = Date.now
        if now.timeIntervalSince(lastReport) >= 0.5 {
            lastReport = now
            progress(have)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        progress(have)
        if let verdict {
            finish(verdict)
        } else if let error {
            finish(.failed((error as? URLError)?.code == .cancelled ? "Stopped." : error.localizedDescription))
        } else {
            finish(.complete(total: total))
        }
        session.finishTasksAndInvalidate()
    }
}

/// C-013: a file counts as done only when its checksum matches what the site listed.
nonisolated enum FileVerifier {
    struct Digests: Sendable {
        var md5: String?
        var sha1: String?
        var sha256: String?
    }

    /// Reads the file once and computes only the checksums asked for.
    static func digests(of url: URL, md5: Bool, sha1: Bool, sha256: Bool) throws -> Digests {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var m = Insecure.MD5()
        var s1 = Insecure.SHA1()
        var s256 = SHA256()
        while true {
            let more: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty else { return false }
                if md5 { m.update(data: chunk) }
                if sha1 { s1.update(data: chunk) }
                if sha256 { s256.update(data: chunk) }
                return true
            }
            if !more { break }
        }
        func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
        return Digests(md5: md5 ? hex(m.finalize()) : nil,
                       sha1: sha1 ? hex(s1.finalize()) : nil,
                       sha256: sha256 ? hex(s256.finalize()) : nil)
    }
}
#endif
