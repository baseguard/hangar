import Darwin
import Foundation
import HangarSecrets
import HangarSupport

/// Reads a password or token from the terminal without echoing it; nil when there is no terminal to ask. Room for
/// the longest secret Hangar takes, its newline and the NUL, so a long one isn't cut short.
func askHidden(_ prompt: String) -> String? {
    var buffer = [CChar](repeating: 0, count: SecretRule.longestValue + 2)
    guard readpassphrase(prompt, &buffer, buffer.count, 0) != nil else { return nil }
    return String(nulTerminated: buffer)
}

/// The first line of standard input, for `--password-stdin` and the like.
func readSecretFromStandardInput() -> String {
    (readLine() ?? "").trimmingCharacters(in: .newlines)
}
