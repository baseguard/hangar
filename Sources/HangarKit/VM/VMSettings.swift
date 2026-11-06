import Foundation
import HangarSupport
import Virtualization

/// The rules for changing a VM's settings, the same for `hangar set` and Hangar.app. Only what changed is
/// checked, so a VM brought from a larger Mac can still change its other settings.
package enum VMSettings {
    package static let screenWidths = 640...7680
    package static let screenHeights = 480...4320

    package static var cpuCounts: ClosedRange<Int> {
        1...min(VZVirtualMachineConfiguration.maximumAllowedCPUCount, ProcessInfo.processInfo.activeProcessorCount)
    }

    package static var largestMemory: UInt64 {
        min(VZVirtualMachineConfiguration.maximumAllowedMemorySize, ProcessInfo.processInfo.physicalMemory)
    }

    /// False for a VM that isn't running; it picks the change up when it starts.
    package static func applySharedFoldersLive(to bundle: VMBundle) throws -> Bool {
        guard bundle.isRunning else { return false }
        _ = try ControlClient.send(.reloadSharedFolders, to: bundle)
        return true
    }

    /// Applies `change` to the stored config. A running VM takes only the changes it doesn't read itself,
    /// unless `appliedLive` says its session has taken this change already. Takes the run lock itself, so it
    /// can't be called inside `VMLibrary.withStoppedVM`.
    @discardableResult
    package static func change(
        _ bundle: VMBundle, appliedLive: Bool = false, _ change: (inout VMConfig) throws -> Void
    ) throws -> VMConfig {
        let runLock = FileLock(url: bundle.lockURL)
        let isStopped = try runLock.tryLock(.exclusive)
        defer { runLock.unlock() }

        return try bundle.updateConfig { config in
            let old = config
            try change(&config)
            if !isStopped, !appliedLive, needsStoppedVM(from: old, to: config) {
                throw VMBundle.stillRunning(bundle.name)
            }
            try check(from: old, to: config)
            reserveAddressIfManaged(&config)
        }
    }

    /// The VM never reads whether it starts with Hangar.app or which user the app signs in as.
    package static func needsStoppedVM(from old: VMConfig, to new: VMConfig) -> Bool {
        var withoutLiveChanges = new
        withoutLiveChanges.autoStart = old.autoStart
        withoutLiveChanges.sshUser = old.sshUser
        return withoutLiveChanges != old
    }

    package static func check(from old: VMConfig, to new: VMConfig) throws {
        try checkHardware(from: old, to: new)
        try checkDevices(from: old, to: new)
        try checkNetwork(from: old, to: new)

        if new.sshUser != old.sshUser, let user = new.sshUser {
            try VMConfig.validate(userName: user)
        }
    }

    private static func checkHardware(from old: VMConfig, to new: VMConfig) throws {
        if new.cpuCount != old.cpuCount, !cpuCounts.contains(new.cpuCount) {
            throw HangarError("A VM can have 1 to \(cpuCounts.upperBound) processors on this Mac.")
        }
        if new.memorySize != old.memorySize, new.memorySize > largestMemory {
            throw HangarError("A VM can have at most \(ByteSize.format(largestMemory)) of memory on this Mac.")
        }
        guard new.display != old.display else { return }

        guard new.os != .windows else {
            let size = WindowsPlatform.display
            throw HangarError(
                "Windows VMs always use \(size.width)x\(size.height); use Remote Desktop for a larger screen.")
        }
        guard screenWidths.contains(new.display.width), screenHeights.contains(new.display.height) else {
            throw HangarError(
                "The screen size must be between \(screenWidths.lowerBound)x\(screenHeights.lowerBound) and "
                    + "\(screenWidths.upperBound)x\(screenHeights.upperBound).")
        }
    }

    /// Also for `hangar run --iso`, which attaches an ISO for one run without saving it.
    package static func checkISO(on os: GuestOS) throws {
        guard os.supportsISO else {
            throw HangarError(
                "Windows can't read ISOs here: it needs a CD drive, which virtual machines on this Mac don't have.")
        }
    }

    private static func checkDevices(from old: VMConfig, to new: VMConfig) throws {
        if new.isoPath != nil, new.isoPath != old.isoPath {
            try checkISO(on: new.os)
        }
        if new.rosetta, !old.rosetta, !new.os.supportsRosetta {
            throw HangarError("Rosetta is for Linux VMs.")
        }
        if new.audio, !old.audio, !new.os.supportsAudio {
            throw HangarError("\(new.os.displayName) VMs have no sound device here.")
        }
        if new.usesNestedVirtualization, !old.usesNestedVirtualization {
            try checkNestedVirtualization(for: new.os)
        }
    }

    /// Also when the VM starts, since it may have come from another Mac.
    package static func checkNestedVirtualization(for os: GuestOS) throws {
        guard os.supportsNestedVirtualization else {
            throw HangarError("Nested virtualization is for Linux and Windows VMs.")
        }
        guard macSupportsNestedVirtualization else {
            throw HangarError("This Mac can't run VMs inside VMs; nested virtualization needs an M3 or later.")
        }
    }

    package static var macSupportsNestedVirtualization: Bool {
        VZGenericPlatformConfiguration.isNestedVirtualizationSupported
    }

    private static func checkNetwork(from old: VMConfig, to new: VMConfig) throws {
        guard new.network.mode != old.network.mode || new.traffic != old.traffic else { return }
        try new.traffic.checkRunnable(on: new.network.mode)
    }

    private static func reserveAddressIfManaged(_ config: inout VMConfig) {
        guard config.network.mode == .managed, config.network.ipAddress == nil else { return }
        config.network.ipAddress = VMLibrary.allocateIPAddress()
    }
}
