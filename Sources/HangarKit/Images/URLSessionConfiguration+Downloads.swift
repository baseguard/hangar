import Foundation

/// Every session Hangar downloads with refuses TLS older than 1.2: images, ISOs, IPSWs, checksum lists, registries
/// and Hangar's own updates.
extension URLSessionConfiguration {
    static var downloads: URLSessionConfiguration {
        requiringTLS12(.default)
    }

    /// A registry's tokens, manifests and blobs, without cookies.
    static var registry: URLSessionConfiguration {
        let configuration = requiringTLS12(.ephemeral)
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    private static func requiringTLS12(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }
}
