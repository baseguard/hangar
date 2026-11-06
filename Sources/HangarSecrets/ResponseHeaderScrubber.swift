import Foundation

/// Puts the placeholder back where a server's answer carries a secret's value in a header, like a redirect's Location,
/// before the guest gets it. A value is found as it is and percent-encoded, as a URL would carry it. The body passes
/// as the server sent it.
package struct ResponseHeaderScrubber: Sendable {
    /// One way a secret's value may appear in a header, and what to put in its place.
    private struct ValueForm: Sendable {
        let name: String
        let text: String
        let placeholder: String
    }

    private let valueForms: [ValueForm]
    /// The secrets put back in this answer, for the traffic log.
    package private(set) var masked: Set<String> = []

    package init(serverName: String, rules: [SecretRule], values: [String: String]) {
        var valueForms: [ValueForm] = []
        for rule in rules where rule.applies(to: serverName) {
            guard let value = values[rule.name] else { continue }
            for form in Self.forms(of: value) {
                valueForms.append(ValueForm(name: rule.name, text: form, placeholder: rule.placeholder))
            }
        }
        self.valueForms = valueForms
    }

    package mutating func scrub(headerValue: String) -> String {
        var scrubbed = headerValue
        for form in valueForms where scrubbed.contains(form.text) {
            scrubbed = scrubbed.replacingOccurrences(of: form.text, with: form.placeholder)
            masked.insert(form.name)
        }
        return scrubbed
    }

    private static func forms(of value: String) -> [String] {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = [
            value.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
            value.addingPercentEncoding(withAllowedCharacters: unreserved),
        ]
        var forms = [value]
        for form in encoded.compactMap({ $0 }) where !forms.contains(form) {
            forms.append(form)
        }
        return forms
    }
}
