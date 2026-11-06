import Foundation
import HangarSupport
import ObjectiveC
import Virtualization

package enum WindowsPlatform {
    /// Windows reads the performance counters while it boots, which Apple's hypervisor gives no guest; this private
    /// setter has Virtualization emulate them.
    private static let emulationSetter = NSSelectorFromString("_setPerformanceMonitoringUnitEmulationEnabled:")

    package static let display = DisplaySettings(width: 1024, height: 768, pixelsPerInch: 96)

    package static var isSupported: Bool {
        VZGenericPlatformConfiguration.instancesRespond(to: emulationSetter)
    }

    static func make(machineIdentifier: Data?) throws -> VZGenericPlatformConfiguration {
        guard isSupported else {
            throw HangarError("This version of macOS cannot run Windows on Virtualization.framework.")
        }

        let platform = VZGenericPlatformConfiguration()

        if let machineIdentifier, let identifier = VZGenericMachineIdentifier(dataRepresentation: machineIdentifier) {
            platform.machineIdentifier = identifier
        }

        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void

        unsafeBitCast(platform.method(for: emulationSetter), to: Setter.self)(platform, emulationSetter, true)

        return platform
    }
}
