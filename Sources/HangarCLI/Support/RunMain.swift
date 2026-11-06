import ArgumentParser
import Foundation
import HangarKit
import HangarSupport
import Synchronization

private let interrupted = Atomic(false)

private func plain(_ error: any Error) -> any Error {
    switch error {
    case let error as ValidationError:
        return HangarError(error.message)
    case let error as URLError:
        let server = error.failingURL?.host(percentEncoded: false).map { " (\($0))" } ?? ""
        return HangarError(error.localizedDescription + server)
    default:
        return error
    }
}

/// The shell's exit status for a command that Control-C ended: 128 plus SIGINT.
private let interruptedExitCode: Int32 = 130

func runMain(_ body: @escaping @MainActor () async throws -> Void) -> Never {
    let task = Task { @MainActor in
        do {
            try await body()
            Hangar.exit()
        } catch  where Task.isCancelled {
            Hangar.exit(withError: ExitCode(interruptedExitCode))
        } catch {
            fflush(stdout)
            Hangar.exit(withError: plain(error))
        }
    }

    let sources = [SIGINT, SIGTERM].map { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            if interrupted.exchange(true, ordering: .relaxed) { Foundation.exit(130) }
            printError("\nCancelling… (press Ctrl+C again to quit at once)")
            task.cancel()
        }
        source.activate()
        return source
    }
    withExtendedLifetime(sources) {
        dispatchMain()
    }
}
