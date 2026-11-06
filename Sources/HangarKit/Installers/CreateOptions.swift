import Foundation

package struct CreateOptions: Sendable {
    package var cpuCount: Int?
    package var memorySize: UInt64?
    package var diskSize: UInt64
    package var network: NetworkMode

    package init(cpuCount: Int? = nil, memorySize: UInt64? = nil, diskSize: UInt64, network: NetworkMode = .managed) {
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.diskSize = diskSize
        self.network = network
    }
}
