import ArgumentParser
import Foundation
import HangarKit
import HangarSupport
import HangarTraffic

extension GuestOS: ExpressibleByArgument {
    package static var allValueStrings: [String] { [] }
}

extension ImageBuilder.Kind: ExpressibleByArgument {}

extension NetworkMode: ExpressibleByArgument {
    package static var allValueStrings: [String] { [] }
}

/// Past any Mac's memory or disk; keeps the multiplication below in range.
private let largestGigabytes = 65_536

func parseGigabytes(_ value: Int, name: String) throws -> UInt64 {
    guard value > 0 else { throw ValidationError("\(name) must be positive.") }
    guard value <= largestGigabytes else { throw ValidationError("\(name) must be at most \(largestGigabytes) GB.") }
    return UInt64(value) * ByteSize.gib
}

/// VMSettings checks these too; checking them here as well names the flag and prints the command's usage.
func validateResources(cpu: Int?, memory: UInt64?) throws {
    if let cpu, !VMSettings.cpuCounts.contains(cpu) {
        throw ValidationError("--cpu must be between 1 and \(VMSettings.cpuCounts.upperBound).")
    }
    if let memory, memory > VMSettings.largestMemory {
        throw ValidationError("--memory can be at most \(ByteSize.format(VMSettings.largestMemory)) on this Mac.")
    }
}

enum OnOff: String, ExpressibleByArgument {
    case on, off
}

extension TrafficPolicy.Mode: ExpressibleByArgument {
    package static var allValueStrings: [String] { [] }
}
