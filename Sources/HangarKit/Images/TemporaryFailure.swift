import Foundation

/// A failure that trying again may get past, unlike a missing image, a refused sign-in or a full disk.
struct TemporaryFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }

    /// A pause that doubles with every attempt, so a busy registry isn't hit again at once.
    static func retryDelay(attempt: Int) -> Duration {
        .milliseconds(500 << attempt)
    }

    private static let droppedConnections: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed,
    ]

    static func isTemporary(_ error: any Error) -> Bool {
        if error is TemporaryFailure { return true }
        guard let urlError = error as? URLError else { return false }
        return droppedConnections.contains(urlError.code)
    }
}
