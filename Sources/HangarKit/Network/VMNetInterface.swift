import Darwin
import Foundation
import HangarPackets
import HangarSupport
import Synchronization
import vmnet

final class VMNetInterface {
    /// vmnet answers a start within moments; much longer means it won't.
    private static let startTimeout: DispatchTimeInterval = .seconds(10)
    /// Padding for frames shorter than Ethernet's minimum, sent as a second piece so nothing is copied.
    private static let zeros = [UInt8](repeating: 0, count: Packet.shortestFrame)

    let mac: [UInt8]
    private let interface: interface_ref
    private let queue: DispatchQueue

    /// What vmnet reports when the interface has started.
    private struct Started: Sendable {
        var status: vmnet_return_t = .VMNET_FAILURE
        var mac: String?
        var maxPacketSize: UInt64 = 0
    }

    init(
        network: vmnet_network_ref, queue: DispatchQueue, macAddress: [UInt8]? = nil,
        onFrame: @escaping ([UInt8]) -> Void
    ) throws {
        let (interface, started) = try Self.startInterface(on: network, allocatesMAC: macAddress == nil, queue: queue)
        do {
            mac = try macAddress ?? Self.allocatedMAC(in: started)
        } catch {
            Self.stopWaiting(interface, queue: queue)
            throw error
        }
        self.interface = interface
        self.queue = queue

        let buffers = PacketBuffers(size: max(Packet.longestFrame, Int(started.maxPacketSize)))
        vmnet_interface_set_event_callback(interface, .VMNET_INTERFACE_PACKETS_AVAILABLE, queue) { _, _ in
            buffers.drain(interface, onFrame: onFrame)
        }
    }

    /// Starts the interface and waits for vmnet to say how it went; an interface that didn't start is stopped.
    private static func startInterface(
        on network: vmnet_network_ref, allocatesMAC: Bool, queue: DispatchQueue
    ) throws -> (interface_ref, Started) {
        let started = DispatchSemaphore(value: 0)
        let outcome = Mutex(Started())
        let description = xpc_dictionary_create(nil, nil, 0)
        if !allocatesMAC {
            xpc_dictionary_set_bool(description, vmnet_allocate_mac_address_key, false)
        }

        let interface = vmnet_interface_start_with_network(network, description, .global(qos: .userInitiated)) {
            result, parameters in
            let mac = parameters.flatMap { xpc_dictionary_get_string($0, vmnet_mac_address_key) }.map {
                String(cString: $0)
            }
            let size = parameters.map { xpc_dictionary_get_uint64($0, vmnet_max_packet_size_key) } ?? 0
            outcome.withLock { $0 = Started(status: result, mac: mac, maxPacketSize: size) }
            started.signal()
        }

        let waited = started.wait(timeout: .now() + startTimeout)
        let result = outcome.withLock { $0 }
        guard let interface else {
            throw HangarError("Could not start a vmnet interface (status \(result.status.rawValue)).")
        }
        guard waited == .success, result.status == .VMNET_SUCCESS else {
            stopWaiting(interface, queue: queue)
            throw HangarError("Could not start a vmnet interface (status \(result.status.rawValue)).")
        }
        return (interface, result)
    }

    private static func allocatedMAC(in started: Started) throws -> [UInt8] {
        guard let mac = started.mac.flatMap(MACAddress.bytes) else {
            throw HangarError("The vmnet interface got no MAC address.")
        }
        return mac
    }

    /// The caller gives up and may exit next; vmnet frees the network only once the interface has stopped, and an
    /// exit before that keeps the subnet busy.
    private static func stopWaiting(_ interface: interface_ref, queue: DispatchQueue) {
        let stopped = DispatchSemaphore(value: 0)
        guard vmnet_stop_interface(interface, queue, { _ in stopped.signal() }) == .VMNET_SUCCESS else { return }
        _ = stopped.wait(timeout: .now() + 10)
    }

    func stop(then stopped: @escaping @Sendable () -> Void = {}) {
        vmnet_interface_set_event_callback(interface, .VMNET_INTERFACE_PACKETS_AVAILABLE, nil, nil)
        if vmnet_stop_interface(interface, queue, { _ in stopped() }) != .VMNET_SUCCESS {
            stopped()
        }
    }

    /// A frame shorter than Ethernet's minimum goes out with zeros after it, as a second piece of the same packet.
    /// vmnet only reads the pieces, though its API takes mutable pointers.
    func send(_ frame: [UInt8]) {
        let padding = max(0, Packet.shortestFrame - frame.count)
        frame.withUnsafeBytes { raw in
            Self.zeros.withUnsafeBytes { zeros in
                var pieces = [
                    iovec(iov_base: UnsafeMutableRawPointer(mutating: raw.baseAddress), iov_len: raw.count),
                    iovec(iov_base: UnsafeMutableRawPointer(mutating: zeros.baseAddress), iov_len: padding),
                ]
                let pieceCount = padding > 0 ? 2 : 1
                pieces.withUnsafeMutableBufferPointer { pointer in
                    guard let first = pointer.baseAddress else { return }
                    var descriptor = vmpktdesc(
                        vm_pkt_size: raw.count + padding, vm_pkt_iov: first, vm_pkt_iovcnt: UInt32(pieceCount),
                        vm_flags: 0)
                    var count: Int32 = 1
                    _ = vmnet_write(interface, &descriptor, &count)
                }
            }
        }
    }
}

private final class PacketBuffers {
    private static let count = 32
    private let size: Int
    private let storage: UnsafeMutableRawPointer
    private let vectors: UnsafeMutablePointer<iovec>
    private let descriptors: UnsafeMutablePointer<vmpktdesc>

    init(size: Int) {
        self.size = size
        storage = .allocate(byteCount: Self.count * size, alignment: 16)
        vectors = .allocate(capacity: Self.count)
        descriptors = .allocate(capacity: Self.count)
        for index in 0..<Self.count {
            vectors[index] = iovec(iov_base: storage + index * size, iov_len: size)
            descriptors[index] = vmpktdesc(
                vm_pkt_size: size, vm_pkt_iov: vectors + index, vm_pkt_iovcnt: 1, vm_flags: 0)
        }
    }

    deinit {
        storage.deallocate()
        vectors.deallocate()
        descriptors.deallocate()
    }

    func drain(_ interface: interface_ref, onFrame: ([UInt8]) -> Void) {
        while true {
            for index in 0..<Self.count {
                vectors[index].iov_len = size
                descriptors[index].vm_pkt_size = size
            }

            var received = Int32(Self.count)
            guard vmnet_read(interface, descriptors, &received) == .VMNET_SUCCESS, received > 0 else {
                return
            }
            for index in 0..<Int(received) {
                onFrame(
                    [UInt8](
                        UnsafeRawBufferPointer(start: storage + index * size, count: descriptors[index].vm_pkt_size)))
            }
        }
    }
}
