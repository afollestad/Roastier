import Foundation
import IOKit.pwr_mgt
import Observation
import os

/// Owns the `caffeinate -dims` assertion set while "Stay awake" is on, and ends it when the selected duration elapses.
@MainActor
@Observable
public final class AwakeController {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    static let durationDefaultsKey = "awakeDurationStep"
    static let relaunchSessionDefaultsKey = "relaunchSession"
    static let assertionReason = "Roastier: Stay awake"
    /// A saved session older than this is from a relaunch that never happened, not one in progress.
    static let relaunchSessionMaxAge: TimeInterval = 60

    public private(set) var isActive = false
    /// When the current session ends; `nil` while inactive or indefinite.
    public private(set) var deadline: Date?
    /// The slider position, persisted across launches. A timed session counts it down to the time left, rounded up to
    /// a whole step, and returns it to indefinite once time is up. Setting it while active restarts the countdown from
    /// now.
    public var duration: AwakeDuration {
        get {
            currentDuration
        }
        set {
            // A rounded slider binding re-sends the same step on every drag tick.
            guard newValue != currentDuration else {
                return
            }
            currentDuration = newValue
            if isActive {
                scheduleExpiry()
            }
        }
    }

    /// The countdown writes this directly so its ticks don't restart the session.
    private var currentDuration: AwakeDuration {
        didSet {
            defaults.set(currentDuration.step, forKey: Self.durationDefaultsKey)
        }
    }

    @ObservationIgnored private let assertionClient: any PowerAssertionClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var assertionIDs: [IOPMAssertionID] = []
    /// Internal so tests can await expiry instead of sleeping.
    @ObservationIgnored private(set) var expiryTask: Task<Void, Never>?

    /// - Parameter sleep: Defaults to `Task.sleep`, whose continuous clock keeps counting while the Mac sleeps, so the
    ///   countdown wakes promptly after a lid-closed nap and catches up from `now`.
    public init(
        assertionClient: any PowerAssertionClient = IOKitPowerAssertionClient(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.assertionClient = assertionClient
        self.defaults = defaults
        self.now = now
        self.sleep = sleep
        currentDuration = AwakeDuration(step: defaults.integer(forKey: Self.durationDefaultsKey))
    }

    isolated deinit {
        expiryTask?.cancel()
        for id in assertionIDs {
            assertionClient.release(id)
        }
    }

    /// Holds whichever assertions macOS grants; stays off only when it grants none.
    public func start() {
        guard holdAssertions() else {
            return
        }
        scheduleExpiry()
    }

    public func stop() {
        expiryTask?.cancel()
        expiryTask = nil
        deadline = nil
        for id in assertionIDs {
            assertionClient.release(id)
        }
        assertionIDs = []
        isActive = false
    }

    /// Records the active session, so the relaunch after an app update can resume it; a no-op while inactive.
    public func saveSessionForRelaunch() {
        guard isActive else {
            return
        }
        var session: [String: Date] = ["savedAt": now()]
        session["deadline"] = deadline
        defaults.set(session, forKey: Self.relaunchSessionDefaultsKey)
    }

    /// Resumes a session saved moments ago by `saveSessionForRelaunch()`, keeping a timed session's original deadline.
    /// Always clears the saved session.
    public func resumeSessionAfterRelaunch() {
        guard let session = defaults.dictionary(forKey: Self.relaunchSessionDefaultsKey) else {
            return
        }
        defaults.removeObject(forKey: Self.relaunchSessionDefaultsKey)
        guard let savedAt = session["savedAt"] as? Date,
              abs(now().timeIntervalSince(savedAt)) <= Self.relaunchSessionMaxAge else {
            return
        }
        guard let deadline = session["deadline"] as? Date else {
            currentDuration = .indefinite
            start()
            return
        }
        guard deadline > now(), holdAssertions(), let wait = tick(until: deadline) else {
            return
        }
        scheduleCountdown(until: deadline, firstWait: wait)
    }

    /// Takes every assertion macOS grants and returns whether the session is now on.
    private func holdAssertions() -> Bool {
        guard !isActive else {
            return false
        }
        assertionIDs = PowerAssertionKind.allCases.compactMap { kind in
            let id = assertionClient.create(kind, reason: Self.assertionReason)
            if id == nil {
                logger.error("Failed to create power assertion \(String(describing: kind), privacy: .public)")
            }
            return id
        }
        guard !assertionIDs.isEmpty else {
            return false
        }
        isActive = true
        return true
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let interval = duration.timeInterval else {
            deadline = nil
            return
        }
        // Sessions are whole steps long, so the first step ends one step from now.
        scheduleCountdown(until: now().addingTimeInterval(interval), firstWait: AwakeDuration.stepInterval)
    }

    private func scheduleCountdown(until deadline: Date, firstWait: TimeInterval) {
        expiryTask?.cancel()
        self.deadline = deadline
        let sleep = self.sleep
        expiryTask = Task { [weak self] in
            var wait = firstWait
            while true {
                do {
                    try await sleep(.seconds(wait))
                } catch {
                    return
                }
                guard !Task.isCancelled, let next = self?.tick(until: deadline) else {
                    return
                }
                wait = next
            }
        }
    }

    /// Counts `duration` down to the time left and returns the wait until its next step, or ends the session and
    /// returns `nil` once time is up. Measuring from `deadline` each tick catches up after a nap spanning several steps.
    private func tick(until deadline: Date) -> TimeInterval? {
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else {
            currentDuration = .indefinite
            stop()
            return nil
        }
        currentDuration = AwakeDuration(roundingUp: remaining)
        return remaining - TimeInterval(currentDuration.step - 1) * AwakeDuration.stepInterval
    }
}

private let logger = Logger(subsystem: "com.afollestad.roastier", category: "AwakeController")
