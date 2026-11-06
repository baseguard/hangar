import Foundation
import HangarSupport
import HangarTraffic

package struct TrafficRuleFile: Codable, Hashable, Sendable {
    package static let sizeLimit = 1 << 20

    package var mode: TrafficPolicy.Mode
    package var allowed: [String]
    package var blocked: [String]
    package var allowsHost: Bool
    package var allowsVMs: Bool
    package var allowsLocalNetwork: Bool
    package var allowsQUIC: Bool
    package var allowsUDP: Bool

    package init(_ policy: TrafficPolicy) {
        mode = policy.mode
        allowed = policy.allowed
        blocked = policy.blocked
        allowsHost = policy.allowsHost
        allowsVMs = policy.allowsVMs
        allowsLocalNetwork = policy.allowsLocalNetwork
        allowsQUIC = policy.allowsQUIC
        allowsUDP = policy.allowsUDP
    }

    package func encoded() throws -> Data {
        try JSON.encoder.encode(self)
    }

    static let keys: Set<String> = [
        "mode", "allowed", "blocked", "allowsHost", "allowsVMs", "allowsLocalNetwork", "allowsQUIC", "allowsUDP",
    ]

    package static func decode(_ data: Data) throws -> TrafficRuleFile {
        guard data.count <= sizeLimit else { throw HangarError("A traffic rules file can be at most 1 MB.") }
        if let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            try JSON.refuseUnknownKeys(in: fields, known: keys, of: "This traffic rules file")
        }

        let file: TrafficRuleFile
        do {
            file = try JSON.decoder.decode(TrafficRuleFile.self, from: data)
        } catch let error as DecodingError {
            throw HangarError("This isn't a Hangar traffic rules file: \(JSON.problem(error)).")
        }
        return try file.normalized()
    }

    func normalized() throws -> TrafficRuleFile {
        var policy = TrafficPolicy()
        try policy.apply(self)
        return TrafficRuleFile(policy)
    }

    package var summary: String {
        let reaches = [(allowsHost, "this Mac"), (allowsVMs, "other VMs"), (allowsLocalNetwork, "the local network")]
        let reachable = reaches.filter(\.0).map(\.1)
        let protocols = [(allowsQUIC, "QUIC"), (allowsUDP, "UDP")].filter(\.0).map(\.1)
        var text = "\(mode.displayName), \(allowed.count) allowed and \(blocked.count) blocked hosts."
        text +=
            reachable.isEmpty
            ? " It can't reach this Mac, other VMs or the local network."
            : " It can reach \(reachable.formatted(.list(type: .and)))."
        if !protocols.isEmpty { text += " \(protocols.formatted(.list(type: .and))) allowed." }
        return text
    }

    package static func read(from url: URL) throws -> TrafficRuleFile {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= sizeLimit else { throw HangarError("A traffic rules file can be at most 1 MB.") }
        return try decode(try Data(contentsOf: url))
    }

    @concurrent
    package static func download(from source: String) async throws -> TrafficRuleFile {
        guard let url = try Downloader.remoteURL(source.trimmingCharacters(in: .whitespaces)) else {
            throw HangarError("Enter an https:// address.")
        }
        return try decode(try await Downloader.data(from: url, limit: sizeLimit, kind: "a traffic rules file"))
    }
}

extension TrafficPolicy {
    package mutating func apply(_ file: TrafficRuleFile) throws {
        let allowedRules = try TrafficRule.normalize(file.allowed)
        let blockedRules = try TrafficRule.normalize(file.blocked)
        try Self.checkCount(allowedRules.count + blockedRules.count)
        let blockedSet = Set(blockedRules)

        if let both = allowedRules.first(where: blockedSet.contains) {
            throw HangarError("'\(both)' is both allowed and blocked.")
        }

        mode = file.mode
        allowed = allowedRules
        blocked = blockedRules
        allowsHost = file.allowsHost
        allowsVMs = file.allowsVMs
        allowsLocalNetwork = file.allowsLocalNetwork
        allowsQUIC = file.allowsQUIC
        allowsUDP = file.allowsUDP
    }
}
