import Foundation

/// The message `body` fails with, so a test checks that a refusal happened for the reason it expects.
func failureMessage<Value>(_ body: () throws -> Value) -> String? {
    do {
        _ = try body()
        return nil
    } catch {
        return error.localizedDescription
    }
}

func failureMessage<Value>(_ body: () async throws -> Value) async -> String? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error.localizedDescription
    }
}
