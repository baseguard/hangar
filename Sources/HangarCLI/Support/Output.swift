import Foundation
import HangarKit

func printError(_ message: String) {
    // Throws instead of raising when nobody reads stderr any more: SIGPIPE is ignored, so the write fails with EPIPE.
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
}

func printFields(_ rows: [(String, String)]) {
    let width = rows.map(\.0.count).max() ?? 0
    for (key, value) in rows {
        print(key.padding(toLength: width + 2, withPad: " ", startingAt: 0) + value)
    }
}

func ipColumn(for config: VMConfig, run: RunInfo?) -> String {
    guard let run else { return config.network.ipAddress ?? "-" }
    return IPResolver.ipAddress(for: config, startedAt: run.startedAt) ?? "…"
}

func printTable(_ rows: [[String]]) {
    guard let header = rows.first else { return }

    var widths = header.map(\.count)

    for row in rows {
        for (index, cell) in row.enumerated() where index < widths.count {
            widths[index] = max(widths[index], cell.count)
        }
    }

    for row in rows {
        let line = row.enumerated().map { index, cell in
            index == row.count - 1 ? cell : cell.padding(toLength: widths[index] + 2, withPad: " ", startingAt: 0)
        }.joined()
        print(line)
    }
}
