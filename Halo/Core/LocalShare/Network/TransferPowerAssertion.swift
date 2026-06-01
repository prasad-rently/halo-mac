import Foundation
import IOKit.pwr_mgt

final class TransferPowerAssertion: @unchecked Sendable {
    private var assertionID: IOPMAssertionID = 0
    private var isActive = false

    func begin(reason: String) {
        guard !isActive else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        isActive = (result == kIOReturnSuccess)
    }

    func end() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        isActive = false
    }

    deinit {
        end()
    }
}
