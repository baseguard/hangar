import Foundation

extension VMConfig {
    static func newVM(_ os: GuestOS, options: CreateOptions) throws -> VMConfig {
        var config = VMConfig(
            os: os,
            cpuCount: options.cpuCount ?? os.defaultCPUCount,
            memorySize: options.memorySize ?? os.defaultMemorySize,
            display: os.defaultDisplay,
            network: NetworkSettings(
                mode: options.network, macAddress: randomMACAddress(), ipAddress: VMLibrary.allocateIPAddress())
        )
        config.machineIdentifier = newMachineIdentifier(for: os)
        config.audio = os.supportsAudio
        return config
    }
}
