import Foundation
import HangarSupport
import Synchronization

final class BlobStream: NSObject, URLSessionDataDelegate, Sendable {
    enum Outcome {
        case finished
        case unauthorized(String, server: URL?)
    }

    private struct State {
        var continuation: CheckedContinuation<Outcome, any Error>?
        var failure: (any Error)?
        var challenge: String?
        var server: URL?
        var task: URLSessionDataTask?
    }

    private let begin: @Sendable (BlobStart) throws -> Void
    private let consume: @Sendable (Data) throws -> Void
    private let state = Mutex(State())

    static func run(
        _ request: URLRequest, begin: @escaping @Sendable (BlobStart) throws -> Void,
        consume: @escaping @Sendable (Data) throws -> Void
    ) async throws -> Outcome {
        let stream = BlobStream(begin: begin, consume: consume)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: RegistryClient.withoutCookies, delegate: stream, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                stream.state.withLock {
                    $0.continuation = continuation
                    $0.task = task
                }
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            stream.state.withLock { $0.task }?.cancel()
        }
    }

    private init(
        begin: @escaping @Sendable (BlobStart) throws -> Void, consume: @escaping @Sendable (Data) throws -> Void
    ) {
        self.begin = begin
        self.consume = consume
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 {
            state.withLock {
                $0.challenge = http?.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
                $0.server = response.url
            }
            completionHandler(.cancel)
        } else if let http, (200..<300).contains(status) {
            do {
                try begin(BlobStart(http))
                completionHandler(.allow)
            } catch {
                state.withLock { $0.failure = error }
                completionHandler(.cancel)
            }
        } else {
            state.withLock {
                $0.failure = RegistryClient.failure(
                    "Download failed: HTTP \(status) from \(response.url?.host ?? "the registry").", status: status)
            }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard state.withLock({ $0.failure == nil }) else { return }
        do {
            try consume(data)
        } catch {
            state.withLock { $0.failure = error }
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(RegistryRedirects.follow(request, from: task.originalRequest?.url))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, challenge, server, failure) = state.withLock { state in
            defer { state.continuation = nil }
            return (state.continuation, state.challenge, state.server, state.failure)
        }
        if let challenge {
            continuation?.resume(returning: .unauthorized(challenge, server: server))
        } else if let failure = failure ?? error {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume(returning: .finished)
        }
    }
}
