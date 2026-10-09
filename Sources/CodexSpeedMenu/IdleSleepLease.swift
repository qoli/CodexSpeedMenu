import Foundation
import IOKit.pwr_mgt
import OSLog

final class IdleSleepLease {
    private let duration: TimeInterval
    private let log: Logger
    private var assertionID: IOPMAssertionID?
    private var expiration: DispatchWorkItem?
    private var generation: UInt = 0

    var isActive: Bool { assertionID != nil }
    private(set) var expiresAt: Date?

    init(
        duration: TimeInterval = 5 * 60,
        log: Logger = Logger(subsystem: "cc.ronniewong.CodexSpeedMenu", category: "power")
    ) {
        self.duration = duration
        self.log = log
    }

    func renew() {
        generation &+= 1
        let scheduledGeneration = generation
        expiration?.cancel()
        let renewedExpiresAt = Date().addingTimeInterval(duration)

        if assertionID == nil {
            var newAssertionID: IOPMAssertionID = 0
            // A display-sleep assertion also prevents idle system sleep while active.
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Recent coding agent response" as CFString,
                &newAssertionID
            )
            guard result == kIOReturnSuccess else {
                expiresAt = nil
                log.error("keep_awake_assertion_create_failed type=PreventUserIdleDisplaySleep return_code=\(result)")
                return
            }
            assertionID = newAssertionID
            expiresAt = renewedExpiresAt
            log.info("keep_awake_assertion_created type=PreventUserIdleDisplaySleep assertion_id=\(newAssertionID) duration_seconds=\(Int(self.duration)) expires_at=\(renewedExpiresAt.timeIntervalSince1970)")
        } else if let assertionID {
            expiresAt = renewedExpiresAt
            log.debug("keep_awake_lease_renewed type=PreventUserIdleDisplaySleep assertion_id=\(assertionID) duration_seconds=\(Int(self.duration)) expires_at=\(renewedExpiresAt.timeIntervalSince1970)")
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == scheduledGeneration else { return }
            self.release(reason: "expired")
        }
        expiration = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func cancel() {
        release(reason: "cancelled")
    }

    private func release(reason: String) {
        generation &+= 1
        expiration?.cancel()
        expiration = nil
        expiresAt = nil
        guard let assertionID else { return }
        let result = IOPMAssertionRelease(assertionID)
        guard result == kIOReturnSuccess else {
            log.error("keep_awake_assertion_release_failed type=PreventUserIdleDisplaySleep assertion_id=\(assertionID) reason=\(reason, privacy: .public) return_code=\(result)")
            return
        }
        self.assertionID = nil
        log.info("keep_awake_assertion_released type=PreventUserIdleDisplaySleep assertion_id=\(assertionID) reason=\(reason, privacy: .public)")
    }

    deinit {
        expiration?.cancel()
        if let assertionID {
            let result = IOPMAssertionRelease(assertionID)
            if result != kIOReturnSuccess {
                log.error("keep_awake_assertion_release_failed type=PreventUserIdleDisplaySleep assertion_id=\(assertionID) reason=deinit return_code=\(result)")
            }
        }
    }
}
