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
    static let assertionReason = "Caffeinate: Stay awake"

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
        guard !isActive else {
            return
        }
        assertionIDs = PowerAssertionKind.allCases.compactMap { kind in
            let id = assertionClient.create(kind, reason: Self.assertionReason)
            if id == nil {
                logger.error("Failed to create power assertion \(String(describing: kind), privacy: .public)")
            }
            return id
        }
        guard !assertionIDs.isEmpty else {
            return
        }
        isActive = true
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

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let interval = duration.timeInterval else {
            deadline = nil
            return
        }
        let deadline = now().addingTimeInterval(interval)
        self.deadline = deadline
        let sleep = self.sleep
        expiryTask = Task { [weak self] in
            // Sessions are whole steps long, so the first step ends one step from now.
            var wait = AwakeDuration.stepInterval
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

private let logger = Logger(subsystem: "com.afollestad.caffeinate", category: "AwakeController")
