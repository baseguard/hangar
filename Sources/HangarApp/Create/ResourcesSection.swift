import Foundation
import HangarSupport
import SwiftUI

struct ResourcesSection: View {
    @Binding var cpus: Int
    @Binding var memoryGB: Int
    @Binding var diskGB: Int
    let minimumDiskGB: Int

    var body: some View {
        Section("Resources") {
            StepperRow(
                title: "Processors", value: "\(cpus)", number: $cpus,
                range: 1...ProcessInfo.processInfo.activeProcessorCount)
            StepperRow(
                title: "Memory", value: "\(memoryGB) GB", number: $memoryGB,
                range: 1...max(1, Int(ProcessInfo.processInfo.physicalMemory / ByteSize.gib)))
            StepperRow(title: "Disk", value: "\(diskGB) GB", number: $diskGB, range: minimumDiskGB...4096, step: 4)
        }
    }
}
