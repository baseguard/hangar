import Foundation

protocol ImageSink: Sendable {
    func upload(_ data: Data, digest: String) async throws
}

extension RegistryClient: ImageSink {}
