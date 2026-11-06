import Foundation

final class RegistryRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RegistryRedirects()

    @concurrent
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        Self.follow(request, from: task.originalRequest?.url)
    }

    static func follow(_ request: URLRequest, from original: URL?) -> URLRequest? {
        let sameServer =
            request.url?.host?.lowercased() == original?.host?.lowercased() && request.url?.port == original?.port
        let plainOnSameServer =
            request.url?.scheme?.lowercased() == "http" && original?.scheme?.lowercased() == "http" && sameServer
        guard request.url?.scheme?.lowercased() == "https" || plainOnSameServer else { return nil }
        guard !sameServer else { return request }
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        return request
    }
}
