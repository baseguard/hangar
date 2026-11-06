import Darwin
import Foundation
import HangarSupport

package struct VMBundle: Hashable, Identifiable, Sendable {
    /// `st_blocks` counts 512-byte blocks whatever the file system's block size.
    static let statBlockSize: UInt64 = 512
    /// A VM started in the background gets this long to report itself running.
    static let startTimeout: TimeInterval = 240
    static let shownLogLines = 8

    package let url: URL

    package init(url: URL) {
        self.url = url
    }

    package var name: String { url.lastPathComponent }
    package var id: String { name }

    package var configURL: URL { url.appendingPathComponent("config.json") }
    package var diskURL: URL { url.appendingPathComponent("disk.img") }
    package var nvramURL: URL { url.appendingPathComponent("nvram.bin") }
    package var cloudInitURL: URL { url.appendingPathComponent("cidata.iso") }
    package var lockURL: URL { url.appendingPathComponent(".lock") }
    var configLockURL: URL { url.appendingPathComponent(".config.lock") }
    package var controlSocketURL: URL { url.appendingPathComponent("control.sock") }
    package var logURL: URL { url.appendingPathComponent("vm.log") }
    package var trafficLogURL: URL { url.appendingPathComponent("traffic.jsonl") }

    package func loadConfig() throws -> VMConfig {
        do {
            return try VMConfig.read(from: configURL)
        } catch let error as DecodingError {
            throw HangarError(
                "Could not read the settings of '\(name)' in \(configURL.path): \(JSON.problem(error)). Restore that file or delete the VM."
            )
        } catch let error as HangarError {
            throw error
        } catch {
            throw HangarError("Could not read \(configURL.path): \(error.localizedDescription)")
        }
    }

    package func saveConfig(_ config: VMConfig) throws {
        try JSON.write(config, to: configURL)
        chmod(configURL.path, 0o600)
    }

    @discardableResult
    package func updateConfig(_ change: (inout VMConfig) throws -> Void) throws -> VMConfig {
        let lock = FileLock(url: configLockURL)
        try lock.lock(.exclusive)
        defer { lock.unlock() }
        let stored = try loadConfig()
        var config = stored
        try change(&config)
        if config != stored { try saveConfig(config) }
        return config
    }

    package var diskSize: UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: diskURL.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    package var allocatedSize: UInt64 {
        var total: UInt64 = 0
        for file in [diskURL, nvramURL] {
            var info = stat()
            if stat(file.path, &info) == 0 {
                total += UInt64(info.st_blocks) * Self.statBlockSize
            }
        }
        return total
    }

    /// Lets a command refuse a smaller disk before it changes anything else.
    package func checkDiskCanGrow(to bytes: UInt64) throws {
        guard bytes >= diskSize else { throw Self.diskCanOnlyGrow(from: diskSize) }
    }

    package static func stillRunning(_ name: String) -> HangarError {
        HangarError("'\(name)' is running. Stop it first.")
    }

    private static func diskCanOnlyGrow(from size: UInt64) -> HangarError {
        HangarError("Disks can only grow (current size \(ByteSize.format(size))).")
    }

    package func resizeDisk(to bytes: UInt64) throws {
        let fd = open(diskURL.path, O_RDWR)
        guard fd >= 0 else { throw HangarError(errno: errno, "Could not open \(diskURL.path)") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw HangarError(errno: errno, "Could not read \(diskURL.path)")
        }
        guard bytes >= UInt64(info.st_size) else { throw Self.diskCanOnlyGrow(from: UInt64(info.st_size)) }
        guard bytes <= UInt64(Int64.max), ftruncate(fd, off_t(bytes)) == 0 else {
            throw HangarError(errno: errno, "Could not grow \(diskURL.path)")
        }
    }

    package var runInfo: RunInfo? {
        guard FileLock.isHeld(lockURL) else { return nil }
        return try? JSON.read(RunInfo.self, from: lockURL)
    }

    package var isRunning: Bool { runInfo != nil }
}

extension VMBundle {
    @discardableResult
    package func startInBackground(arguments extra: [String] = []) throws -> pid_t {
        let arguments = ["run", name, "--no-graphics"] + extra
        let pid = try ProcessUtil.spawnDetached(HangarExecutable.url, arguments: arguments, logURL: logURL)
        var state: MachineState?
        _ = ProcessUtil.wait(timeout: Self.startTimeout) {
            state = (try? ControlClient.send(.status, to: self, timeout: 2))?.machineState
            return state == .running || ProcessUtil.hasExited(pid)
        }
        guard state == .running else {
            let lastLines = LogFile.lastLines(Self.shownLogLines, of: logURL).joined(separator: "\n")
            throw HangarError("'\(name)' failed to start:\n\(lastLines)")
        }
        return pid
    }
}
