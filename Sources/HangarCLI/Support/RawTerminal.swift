import Darwin
import Foundation
import HangarKit
import Synchronization

enum RawTerminal {
    private static let original = Mutex<termios?>(nil)

    static func enable() {
        guard isatty(STDIN_FILENO) != 0 else { return }
        var attributes = termios()
        tcgetattr(STDIN_FILENO, &attributes)
        original.withLock { $0 = attributes }
        cfmakeraw(&attributes)
        attributes.c_oflag |= tcflag_t(OPOST)
        tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
        atexit { RawTerminal.restore() }
    }

    static func restore() {
        guard var attributes = original.withLock({ $0.take() }) else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
    }
}
