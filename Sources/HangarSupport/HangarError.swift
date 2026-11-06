import Foundation

package struct HangarError: LocalizedError, CustomStringConvertible, Sendable {
    package let message: String

    package init(_ message: String) {
        self.message = message
    }

    /// Takes errno before the message, so building the message can't change it first.
    package init(errno code: Int32, _ action: String) {
        self.init("\(action): \(String(cString: strerror(code))).")
    }

    package var errorDescription: String? { message }
    package var description: String { message }
}
