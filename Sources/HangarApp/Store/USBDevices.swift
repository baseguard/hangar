import AccessoryAccess
import Foundation
import HangarKit
import HangarSupport
import IOKit
import Observation
import Virtualization

@Observable
final class USBDevices {
    private static let idVendorOffset = 8
    private static let idProductOffset = 10

    static let shared = USBDevices()

    struct Device: Identifiable {
        let accessory: AAUSBAccessory
        let name: String

        var id: UInt64 { accessory.registryID }
    }

    private struct Attachment {
        let vm: String
        let device: VZUSBPassthroughDevice
    }

    private(set) var devices: [Device] = []
    private(set) var unavailableReason: String?
    private var attachments: [UInt64: Attachment] = [:]
    @ObservationIgnored private var listener: Listener?
    /// The USB controllers' delegate, kept here because a controller holds its delegate weakly.
    @ObservationIgnored private let controllerWatch = ControllerWatch(
        disconnected: { device in Task { @MainActor in USBDevices.shared.forget(passthrough: device) } })

    private init() {}

    func startListening() {
        guard listener == nil else { return }
        let listener = Listener(
            connected: { accessory in Task { @MainActor in USBDevices.shared.add(accessory) } },
            disconnected: { accessory in Task { @MainActor in USBDevices.shared.remove(accessory.registryID) } }
        )
        self.listener = listener
        AAUSBAccessoryManager.shared.registerListener(listener, matchingCriteria: []) { accessories, error in
            Task { @MainActor in
                let devices = USBDevices.shared
                if let error {
                    devices.unavailableReason =
                        "USB isn't available: \(error.localizedDescription). Hangar needs a signed build for USB."
                    devices.listener = nil
                    return
                }
                for accessory in accessories {
                    devices.add(accessory)
                }
            }
        }
    }

    /// macOS shows its Virtual Machine Accessories menu while Hangar listens, so it listens only while a VM runs in it.
    func stopListening() {
        guard let listener else { return }
        AAUSBAccessoryManager.shared.unregisterListener(listener) {}
        self.listener = nil
        devices = []
        attachments = [:]
    }

    func owner(of device: Device) -> String? {
        attachments[device.id]?.vm
    }

    func attach(_ device: Device, to session: VMSession) async throws {
        guard let controller = session.virtualMachine.usbControllers.first else {
            throw HangarError("'\(session.name)' has no USB controller. Shut it down and start it in Hangar again.")
        }

        let passthrough = try VZUSBPassthroughDevice(
            configuration: VZUSBPassthroughDeviceConfiguration(device: device.accessory))
        controller.delegate = controllerWatch
        try await controller.attach(device: passthrough)
        guard devices.contains(where: { $0.id == device.id }), VMStore.shared.sessions[session.name] === session else {
            return
        }
        attachments[device.id] = Attachment(vm: session.name, device: passthrough)
    }

    func detach(_ device: Device) async throws {
        guard let attachment = attachments[device.id] else { return }
        if let controller = attachment.device.usbController {
            try await controller.detach(device: attachment.device)
        }
        attachments[device.id] = nil
    }

    func forget(vm name: String) {
        attachments = attachments.filter { $0.value.vm != name }
    }

    /// Virtualization already detached the device, because it left the Mac.
    private func forget(passthrough device: ObjectIdentifier) {
        attachments = attachments.filter { ObjectIdentifier($0.value.device) != device }
    }

    private func add(_ accessory: AAUSBAccessory) {
        guard !devices.contains(where: { $0.id == accessory.registryID }) else { return }
        devices.append(Device(accessory: accessory, name: Self.name(of: accessory)))
        devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func remove(_ id: UInt64) {
        devices.removeAll { $0.id == id }
        attachments[id] = nil
    }

    private static func name(of accessory: AAUSBAccessory) -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(accessory.registryID))
        if service != 0 {
            defer { IOObjectRelease(service) }
            for key in ["kUSBProductString", "USB Product Name"] {
                if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String, !value.isEmpty
                {
                    return value
                }
            }
        }

        // In a USB device descriptor, idVendor and idProduct are little-endian at 8 and 10.
        let descriptor = [UInt8](accessory.deviceDescriptorData)
        guard descriptor.count >= Self.idProductOffset + 2 else { return "USB device" }
        let vendor = UInt16(descriptor[Self.idVendorOffset]) | UInt16(descriptor[Self.idVendorOffset + 1]) << 8
        let product = UInt16(descriptor[Self.idProductOffset]) | UInt16(descriptor[Self.idProductOffset + 1]) << 8
        return String(format: "USB device %04x:%04x", vendor, product)
    }
}

private final class Listener: NSObject, AAUSBAccessoryListener, Sendable {
    private let connected: @Sendable (AAUSBAccessory) -> Void
    private let disconnected: @Sendable (AAUSBAccessory) -> Void

    init(
        connected: @escaping @Sendable (AAUSBAccessory) -> Void,
        disconnected: @escaping @Sendable (AAUSBAccessory) -> Void
    ) {
        self.connected = connected
        self.disconnected = disconnected
    }

    func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        connected(usbAccessory)
    }

    func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        disconnected(usbAccessory)
    }
}

/// Hears from a VM's USB controller when Virtualization detached a passthrough device because it left the Mac.
private final class ControllerWatch: NSObject, VZUSBController.Delegate, Sendable {
    private let disconnected: @Sendable (ObjectIdentifier) -> Void

    init(disconnected: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.disconnected = disconnected
    }

    // Virtualization calls this on the VM's queue, not on the main actor.
    nonisolated func usbController(
        _ usbController: VZUSBController, usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice
    ) {
        disconnected(ObjectIdentifier(device))
    }
}
