import Darwin
import Foundation
import HangarSupport
import vmnet

package final class SharedNetworkLease {
    package let serialization: Data
    package let state: SharedNetwork.State
    private let usersLock: FileLock

    package static func acquire() throws -> SharedNetworkLease {
        try HangarPaths.createDirectory(SharedNetwork.directory)
        let usersLock = FileLock(url: SharedNetwork.usersLockURL)
        try usersLock.lock(.shared)
        let state = try SharedNetwork.ensureDaemon()

        guard let data = try? Data(contentsOf: SharedNetwork.serializationURL), !data.isEmpty else {
            throw HangarError("The network daemon did not publish its network.")
        }
        return SharedNetworkLease(serialization: data, state: state, usersLock: usersLock)
    }

    static func join(_ data: Data) throws -> vmnet_network_ref {
        let serialization = xpc_dictionary_create(nil, nil, 0)
        data.withUnsafeBytes { buffer in
            guard let bytes = buffer.baseAddress else { return }
            xpc_dictionary_set_data(serialization, SharedNetwork.serializationKey, bytes, buffer.count)
        }

        var status: vmnet_return_t = .VMNET_SUCCESS
        guard let network = vmnet_network_create_with_serialization(serialization, &status) else {
            throw HangarError("Could not join Hangar's network (vmnet status \(status.rawValue)).")
        }
        return network
    }

    private init(serialization: Data, state: SharedNetwork.State, usersLock: FileLock) {
        self.serialization = serialization
        self.state = state
        self.usersLock = usersLock
    }

    deinit {
        usersLock.unlock()
    }
}
