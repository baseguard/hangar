import CryptoKit
import Foundation
import HangarSupport
import Synchronization

package final class Downloader: NSObject, URLSessionDownloadDelegate, Sendable {
    package typealias Progress = @Sendable (_ received: Int64, _ expected: Int64) -> Void

    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var task: URLSessionDownloadTask?
        var finishError: (any Error)?
    }

    private let destination: URL
    private let progress: Progress
    private let state = Mutex(State())

    private var resumeURL: URL { destination.appendingPathExtension("resume") }

    /// Cache names start with this many hex digits of the URL's hash, so two sources never share a file.
    package static let cacheKeyLength = 12
    private static let sha256HexLength = 64
    private static let sha512HexLength = 128
    private static let hashPiece = 4 << 20

    /// Small files, like checksum lists and rules files, come within 30 seconds or not at all.
    private static let smallFiles: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    @concurrent
    package static func download(
        from url: URL, to destination: URL, phase: String,
        progress: @escaping ProgressHandler
    ) async throws {
        try await download(from: url, to: destination) { received, expected in
            progress(
                CreationProgress(
                    phase: phase,
                    fraction: expected > 0 ? Double(received) / Double(expected) : nil,
                    detail:
                        "\(ByteSize.format(UInt64(received))) of \(expected > 0 ? ByteSize.format(UInt64(expected)) : "?")"
                ))
        }
    }

    /// A file on this Mac as it is, or one from an https address, downloaded once into `cache`.
    @concurrent
    package static func localFile(
        for source: String, in cache: URL = HangarPaths.isoCache, fallbackName: String = "image.iso",
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        guard let url = try remoteURL(source) else {
            let local = URL(userPath: source).standardizedFileURL
            guard FileManager.default.fileExists(atPath: local.path) else {
                throw HangarError("File not found: \(local.path)")
            }
            return local
        }

        let file = cache.appendingPathComponent(cacheName(for: url, fallback: fallbackName))
        return try await cached(url, as: file, phase: "Downloading \(url.lastPathComponent)", progress: progress)
    }

    @concurrent
    static func cached(
        _ url: URL, as file: URL, digest: String? = nil, phase: String,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        if FileManager.default.fileExists(atPath: file.path) {
            CacheStore.markUsed(file)
            return file
        }

        try HangarPaths.createDirectory(file.deletingLastPathComponent())
        let lockURL = file.appendingPathExtension("lock")
        let lock = FileLock(url: lockURL)

        try await lock.lockWaiting("Waiting for another download of \(file.lastPathComponent)", progress: progress)
        defer {
            if FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.removeItem(at: lockURL) }
            lock.unlock()
        }
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let partial = file.appendingPathExtension("download")
        try await download(from: url, to: partial, phase: phase, progress: progress)

        if let digest, try hash(of: partial, like: digest) != digest {
            try? FileManager.default.removeItem(at: partial)
            throw HangarError("The download from \(url.absoluteString) does not match its known checksum.")
        }

        try FileManager.default.moveItem(at: partial, to: file)

        return file
    }

    static func sha256(of file: URL) throws -> String {
        try hash(of: file, using: SHA256())
    }

    static func hash(of file: URL, like digest: String) throws -> String {
        digest.count == sha512HexLength ? try hash(of: file, using: SHA512()) : try sha256(of: file)
    }

    private static func hash<Function: HashFunction>(of file: URL, using function: Function) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = function
        while let chunk = try handle.readPiece(upToCount: hashPiece), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().hex
    }

    @concurrent
    static func data(from url: URL, limit: Int, kind: String) async throws -> Data {
        let (bytes, response) = try await smallFiles.bytes(from: url, delegate: HTTPSRedirects.shared)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            http.url?.scheme == "https"
        else {
            throw HangarError("Could not read \(kind) at \(url.absoluteString).")
        }

        var data = Data()

        for try await byte in bytes {
            data.append(byte)
            guard data.count <= limit else {
                throw HangarError("\(url.absoluteString) is larger than \(kind) should be.")
            }
        }

        return data
    }

    @concurrent
    static func checksum(of name: String, listedIn sums: URL) async throws -> String {
        let data = try await data(from: sums, limit: 1 << 20, kind: "a checksum list")
        guard let digest = checksum(of: name, in: String(decoding: data, as: UTF8.self)) else {
            throw HangarError("\(sums.absoluteString) has no checksum for \(name).")
        }
        return digest
    }

    static func checksum(of name: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let digest = String(fields[0])
            var listed = fields[1].drop { $0 == " " }
            if listed.first == "*" { listed = listed.dropFirst() }
            guard listed == name, [sha256HexLength, sha512HexLength].contains(digest.count),
                digest.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
            else { continue }
            return digest
        }
        return nil
    }

    static func remoteURL(_ source: String) throws -> URL? {
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http"
        else {
            return nil
        }
        guard scheme == "https" else {
            throw HangarError("Use an https:// address; Hangar doesn't download over plain http.")
        }
        return url
    }

    package static func cacheName(for url: URL, fallback: String) -> String {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).hex.prefix(cacheKeyLength)
        let name = url.lastPathComponent.replacingOccurrences(of: "/", with: "")
        let safe = name.isEmpty || name == "." || name == ".." ? fallback : name
        return "\(key)-\(safe)"
    }

    @concurrent
    package static func download(from url: URL, to destination: URL, progress: @escaping Progress) async throws {
        try HangarPaths.createDirectory(destination.deletingLastPathComponent())
        let downloader = Downloader(destination: destination, progress: progress)
        try await downloader.run(url)
    }

    private init(destination: URL, progress: @escaping Progress) {
        self.destination = destination
        self.progress = progress
    }

    private func run(_ url: URL) async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let task: URLSessionDownloadTask
                if let resumeData = try? Data(contentsOf: resumeURL) {
                    try? FileManager.default.removeItem(at: resumeURL)
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    task = session.downloadTask(with: url)
                }
                state.withLock {
                    $0.continuation = continuation
                    $0.task = task
                }
                task.resume()
                if Task.isCancelled { cancel() }
            }
        } onCancel: {
            cancel()
        }
    }

    private func cancel() {
        state.withLock { $0.task }?.cancel(byProducingResumeData: { [resumeURL] data in
            try? data?.write(to: resumeURL)
        })
    }

    package func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    @concurrent
    package func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard request.url?.scheme?.lowercased() != "https" else { return request }
        let failure = HangarError("Download refused: \(response.url?.absoluteString ?? "") redirects to plain http.")
        state.withLock { $0.finishError = failure }
        return nil
    }

    package func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            let failure = HangarError(
                "Download failed: HTTP \(response.statusCode) for \(response.url?.absoluteString ?? "")")
            state.withLock { $0.finishError = $0.finishError ?? failure }
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            state.withLock { $0.finishError = error }
        }
    }

    package func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error, let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? resumeData.write(to: resumeURL)
        }

        let (continuation, finishError) = state.withLock { state in
            defer { state.continuation = nil }
            return (state.continuation, state.finishError)
        }
        if let error = error ?? finishError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

final class HTTPSRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = HTTPSRedirects()

    @concurrent
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }
}
