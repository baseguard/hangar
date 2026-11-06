import HangarSupport
import HangarTraffic

extension TrafficPolicy {
    package func checkRunnable(on network: NetworkMode) throws {
        try validate()
        guard enforces, network != .managed else { return }
        if isolated {
            throw HangarError(
                "Isolation only works on the Hangar Managed network; switch the network to Hangar Managed, or stop isolating the VM."
            )
        }
        throw HangarError(
            "Traffic rules only apply on the Hangar Managed network; switch the network to Hangar Managed, or the traffic mode to Monitor or Off."
        )
    }
}
