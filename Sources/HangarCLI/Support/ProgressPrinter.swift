import Darwin
import Foundation
import HangarKit
import HangarSupport
import Synchronization

/// Progress goes to stderr, so a script reading stdout gets only the results.
final class ProgressPrinter: Sendable {
    private struct State {
        var lastPhase: String?
        var lastRender = Date.distantPast
    }

    private let state = Mutex(State())
    private let interactive = isatty(STDERR_FILENO) != 0
    /// A line is redrawn at most this often, and the bar is this many characters wide.
    private static let renderInterval: TimeInterval = 0.2
    private static let barWidth = 30

    func update(_ progress: CreationProgress) {
        state.withLock { state in
            let phaseChanged = progress.phase != state.lastPhase
            if !phaseChanged, Date().timeIntervalSince(state.lastRender) < Self.renderInterval, progress.fraction != 1 {
                return
            }
            if phaseChanged, state.lastPhase != nil, interactive {
                Self.write("\n")
            }
            state.lastPhase = progress.phase
            state.lastRender = Date()

            var line = progress.phase
            if let fraction = progress.fraction {
                line += String(format: "  %5.1f%%", fraction * 100)
                if interactive {
                    let width = Self.barWidth
                    let filled = Int(fraction * Double(width))
                    line +=
                        "  [" + String(repeating: "=", count: filled) + String(repeating: " ", count: width - filled)
                        + "]"
                }
            }
            if let detail = progress.detail {
                line += "  " + detail
            }
            if interactive {
                Self.write("\r\u{1B}[2K" + Self.fitted(line))
            } else if phaseChanged {
                Self.write(line + "\n")
            }
        }
    }

    func finish() {
        state.withLock { state in
            if interactive, state.lastPhase != nil { Self.write("\n") }
            state.lastPhase = nil
        }
    }

    private static func write(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    }

    /// A line wider than the terminal wraps, and clearing only its last row would leave the rest on screen.
    private static func fitted(_ line: String) -> String {
        var size = winsize()
        guard ioctl(STDERR_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 1 else { return line }
        return String(line.prefix(Int(size.ws_col) - 1))
    }
}
