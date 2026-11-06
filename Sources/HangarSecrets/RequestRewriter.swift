import Foundation

/// A request's head as the rewriter sees it; `GuestRequests` converts NIO's to and from it.
package struct RequestHead: Equatable, Sendable {
    package struct Field: Equatable, Sendable {
        package var name: String
        package var value: String

        package init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    package var method: String
    package var uri: String
    package var fields: [Field]

    package init(method: String, uri: String, fields: [Field]) {
        self.method = method
        self.uri = uri
        self.fields = fields
    }

    func values(of name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    mutating func set(_ name: String, to value: String) {
        remove(name)
        fields.append(Field(name, value))
    }

    mutating func remove(_ name: String) {
        fields.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// What the secrets proxy does with one request to a host with a secret, decided from its head alone: the checks that
/// keep a secret on its own host, and the headers where its placeholder becomes the value. Only headers get a value:
/// the URL and the body go to the server as the guest sent them.
package struct RequestRewriter: Sendable {
    package struct Refusal: Error, Equatable {
        package let status: Int
        package let message: String
    }

    package enum Verdict: Equatable {
        case forward(RequestHead, used: [String])
        case refuse(Refusal)
    }

    package let serverName: String
    let rules: [SecretRule]
    let values: [String: String]

    package init(serverName: String, rules: [SecretRule], values: [String: String]) {
        self.serverName = serverName.lowercased()
        self.rules = rules
        self.values = values
    }

    private var boundRules: [SecretRule] { rules.filter { $0.applies(to: serverName) } }
    private var foreignRules: [SecretRule] { rules.filter { !$0.applies(to: serverName) } }

    package func rewrite(_ head: RequestHead) -> Verdict {
        if let refusal = refusal(of: head) { return .refuse(refusal) }

        var rewritten = head
        var used: [String] = []
        for rule in boundRules {
            guard let value = values[rule.name] else { continue }
            let before = rewritten
            put(value, of: rule, into: &rewritten)
            if rewritten != before { used.append(rule.name) }
        }
        return .forward(rewritten, used: used)
    }

    /// Every header that holds the placeholder, and the rule's own header on every request.
    private func put(_ value: String, of rule: SecretRule, into head: inout RequestHead) {
        for index in head.fields.indices {
            head.fields[index].value = head.fields[index].value.replacingOccurrences(of: rule.placeholder, with: value)
        }
        if let header = rule.header {
            head.set(header.name, to: header.format.replacingOccurrences(of: SecretRule.valueMarker, with: value))
        }
    }

    private func refusal(of head: RequestHead) -> Refusal? {
        if head.method == "CONNECT" {
            return Refusal(status: 405, message: "Hangar doesn't tunnel through a host with a secret.")
        }
        if !head.values(of: "Upgrade").isEmpty {
            return Refusal(status: 501, message: "Hangar doesn't open WebSocket connections to a host with a secret.")
        }
        if let refusal = framingRefusal(head) { return refusal }
        guard isForServer(head) else {
            return Refusal(
                status: 421, message: "This request names another host than the connection's \(serverName).")
        }
        if let foreign = foreignRules.first(where: { contains($0.placeholder, head) }) {
            return Refusal(status: 403, message: Self.foreignMessage(foreign))
        }
        return nil
    }

    /// Two lengths, or a length and chunks, let a request mean one thing here and another at the server.
    private func framingRefusal(_ head: RequestHead) -> Refusal? {
        let lengths = head.values(of: "Content-Length")
        let isChunked = !head.values(of: "Transfer-Encoding").isEmpty
        guard lengths.count > 1 || (isChunked && !lengths.isEmpty) else { return nil }
        return Refusal(status: 400, message: "The request gives its body's length twice.")
    }

    /// The Host field, and a full URL as the target, must both name the server the connection was opened for.
    private func isForServer(_ head: RequestHead) -> Bool {
        let hosts = head.values(of: "Host")
        guard hosts.count == 1, let host = hosts.first, Self.hostName(host) == serverName else { return false }
        if head.uri.hasPrefix("/") || head.uri == "*" { return true }
        return URLComponents(string: head.uri)?.host?.lowercased() == serverName
    }

    private func contains(_ placeholder: String, _ head: RequestHead) -> Bool {
        head.uri.contains(placeholder) || head.fields.contains { $0.value.contains(placeholder) }
    }

    private static func hostName(_ field: String) -> String {
        let name = field.split(separator: ":", maxSplits: 1).first.map(String.init) ?? field
        return name.lowercased()
    }

    private static func foreignMessage(_ rule: SecretRule) -> String {
        "Secret \(rule.name) belongs to \(rule.hosts.joined(separator: ", ")), not to this host."
    }
}
