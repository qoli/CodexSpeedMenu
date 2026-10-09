import Foundation
import OSLog

final class IdleSleepLease {
    private let duration: TimeInterval
    private let processInfo: ProcessInfo
    private let log: Logger
    private var activity: NSObjectProtocol?
    private var expiration: DispatchWorkItem?
    private var generation: UInt = 0

    var isActive: Bool { activity != nil }

    init(
        duration: TimeInterval = 5 * 60,
        processInfo: ProcessInfo = .processInfo,
        log: Logger = Logger(subsystem: "cc.ronniewong.CodexSpeedMenu", category: "power")
    ) {
        self.duration = duration
        self.processInfo = processInfo
        self.log = log
    }

    func renew() {
        generation &+= 1
        let scheduledGeneration = generation
        expiration?.cancel()

        if activity == nil {
            activity = processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "Recent Codex response"
            )
            log.info("idle_sleep_lease_acquired duration_seconds=\(Int(self.duration))")
        } else {
            log.info("idle_sleep_lease_renewed duration_seconds=\(Int(self.duration))")
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
        guard let activity else { return }
        self.activity = nil
        processInfo.endActivity(activity)
        log.info("idle_sleep_lease_released reason=\(reason, privacy: .public)")
    }

    deinit {
        expiration?.cancel()
        if let activity {
            processInfo.endActivity(activity)
        }
    }
}
