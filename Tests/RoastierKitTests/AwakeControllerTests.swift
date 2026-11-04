import Foundation
import Testing
@testable import RoastierKit

@MainActor
final class AwakeControllerTests {
    private let suiteName = "AwakeControllerTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let client = FakePowerAssertionClient()
    private let clock = FakeClock()

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    @Test
    func startHoldsEveryDimsAssertionAndStopReleasesThem() {
        let controller = makeController()

        controller.start()
        #expect(controller.isActive)
        #expect(client.created.count == PowerAssertionKind.allCases.count)
        #expect(Set(client.created) == Set(PowerAssertionKind.allCases))

        controller.stop()
        #expect(!controller.isActive)
        #expect(client.held.isEmpty)
        #expect(client.released.count == PowerAssertionKind.allCases.count)
    }

    @Test
    func startWhileActiveIsNoOp() {
        let controller = makeController()
        controller.start()
        controller.start()
        #expect(client.created.count == PowerAssertionKind.allCases.count)
    }

    @Test
    func indefiniteSessionHasNoDeadline() {
        let controller = makeController()
        controller.start()
        #expect(controller.duration == .indefinite)
        #expect(controller.deadline == nil)
        #expect(controller.expiryTask == nil)
    }

    @Test
    func timedSessionCountsDownToIndefinite() async {
        let controller = makeController(sleep: advancingSleep)
        controller.duration = AwakeDuration(step: 6)
        var steps: [Int] = []
        clock.onSleep = { [weak controller] in
            steps.append(controller?.duration.step ?? -1)
        }

        controller.start()
        #expect(controller.deadline == clock.now.addingTimeInterval(1_800))

        await controller.expiryTask?.value
        #expect(clock.sleeps == Array(repeating: .seconds(300), count: 6))
        #expect(steps == [6, 5, 4, 3, 2, 1])
        #expect(controller.duration == .indefinite)
        #expect(makeController().duration == .indefinite)
        #expect(!controller.isActive)
        #expect(controller.deadline == nil)
        #expect(client.held.isEmpty)
    }

    @Test
    func countdownCatchesUpAfterOversleeping() async {
        let controller = makeController(sleep: advancingSleep)
        controller.duration = AwakeDuration(step: 12)
        var steps: [Int] = []
        clock.onSleep = { [weak controller] in
            steps.append(controller?.duration.step ?? -1)
        }
        clock.oversleep = 1_200

        controller.start()
        let deadline = controller.deadline

        await controller.expiryTask?.value
        #expect(steps == [12, 7, 6, 5, 4, 3, 2, 1])
        #expect(clock.now == deadline)
        #expect(!controller.isActive)
    }

    @Test
    func stopMidCountdownKeepsTimeLeft() async {
        let controller = makeController(sleep: advancingSleep)
        controller.duration = AwakeDuration(step: 6)
        var sleepCount = 0
        clock.onSleep = { [weak controller] in
            sleepCount += 1
            if sleepCount == 3 {
                controller?.stop()
            }
        }

        controller.start()
        let task = controller.expiryTask

        await task?.value
        #expect(!controller.isActive)
        #expect(controller.duration == AwakeDuration(step: 4))
        #expect(makeController().duration == AwakeDuration(step: 4))
        #expect(client.held.isEmpty)
    }

    @Test
    func changingDurationWhileActiveRestartsFromNow() {
        let controller = makeController()
        controller.duration = AwakeDuration(step: 12)
        controller.start()
        let firstTask = controller.expiryTask

        clock.now.addTimeInterval(600)
        controller.duration = AwakeDuration(step: 6)
        #expect(controller.deadline == clock.now.addingTimeInterval(1_800))
        #expect(firstTask?.isCancelled == true)

        controller.duration = .indefinite
        #expect(controller.isActive)
        #expect(controller.deadline == nil)
        #expect(controller.expiryTask == nil)
    }

    @Test
    func cancelledExpiryDoesNotStopRescheduledSession() async {
        // Sleeps return normally once cancelled, so the replaced session wakes while the rescheduled one keeps waiting.
        let controller = makeController(sleep: { _ in try? await Task.sleep(for: .seconds(3_600)) })
        controller.duration = AwakeDuration(step: 12)
        controller.start()
        let replacedTask = controller.expiryTask

        controller.duration = AwakeDuration(step: 6)
        await replacedTask?.value
        #expect(controller.isActive)
        #expect(controller.duration == AwakeDuration(step: 6))
        #expect(client.held.count == PowerAssertionKind.allCases.count)
    }

    @Test
    func stopCancelsPendingExpiry() async {
        let controller = makeController()
        controller.duration = AwakeDuration(step: 1)
        controller.start()
        let task = controller.expiryTask

        controller.stop()
        #expect(task?.isCancelled == true)
        await task?.value
        #expect(!controller.isActive)
        #expect(controller.deadline == nil)
    }

    @Test
    func changingDurationWhileInactivePersistsWithoutAssertions() {
        let controller = makeController()
        controller.duration = AwakeDuration(step: 3)
        #expect(client.created.isEmpty)
        #expect(controller.deadline == nil)
        #expect(makeController().duration == AwakeDuration(step: 3))
    }

    @Test
    func keepsGrantedAssertionsWhenSomeFail() {
        client.failingKinds = [.preventSystemSleep]
        let controller = makeController()
        controller.start()
        #expect(controller.isActive)
        #expect(client.held.count == PowerAssertionKind.allCases.count - 1)
    }

    @Test
    func staysInactiveWhenEveryAssertionFails() {
        client.failingKinds = Set(PowerAssertionKind.allCases)
        let controller = makeController()
        controller.start()
        #expect(!controller.isActive)
        #expect(controller.deadline == nil)
    }

    @Test
    func resumesIndefiniteSessionAfterRelaunch() {
        let controller = makeController()
        controller.start()
        controller.saveSessionForRelaunch()

        clock.now.addTimeInterval(5)
        let relaunched = makeController()
        relaunched.resumeSessionAfterRelaunch()
        #expect(relaunched.isActive)
        #expect(relaunched.duration == .indefinite)
        #expect(relaunched.deadline == nil)
        #expect(savedRelaunchSession == nil)
    }

    @Test
    func resumesTimedSessionAtItsOriginalDeadline() async {
        let controller = makeController()
        controller.duration = AwakeDuration(step: 6)
        controller.start()
        let deadline = controller.deadline
        clock.now.addTimeInterval(395)
        controller.saveSessionForRelaunch()

        clock.now.addTimeInterval(5)
        let relaunched = makeController(sleep: advancingSleep)
        var steps: [Int] = []
        clock.onSleep = { [weak relaunched] in
            steps.append(relaunched?.duration.step ?? -1)
        }
        relaunched.resumeSessionAfterRelaunch()
        #expect(relaunched.isActive)
        #expect(relaunched.deadline == deadline)
        #expect(relaunched.duration == AwakeDuration(step: 5))

        await relaunched.expiryTask?.value
        #expect(clock.sleeps == [.seconds(200)] + Array(repeating: .seconds(300), count: 4))
        #expect(steps == [5, 4, 3, 2, 1])
        #expect(clock.now == deadline)
        #expect(!relaunched.isActive)
    }

    @Test
    func ignoresStaleRelaunchSession() {
        let controller = makeController()
        controller.start()
        controller.saveSessionForRelaunch()

        clock.now.addTimeInterval(AwakeController.relaunchSessionMaxAge + 1)
        let relaunched = makeController()
        relaunched.resumeSessionAfterRelaunch()
        #expect(!relaunched.isActive)
        #expect(savedRelaunchSession == nil)
    }

    @Test
    func ignoresRelaunchSessionWhoseDeadlinePassed() {
        let controller = makeController()
        controller.duration = AwakeDuration(step: 1)
        controller.start()
        clock.now.addTimeInterval(290)
        controller.saveSessionForRelaunch()

        clock.now.addTimeInterval(20)
        let relaunched = makeController()
        relaunched.resumeSessionAfterRelaunch()
        #expect(!relaunched.isActive)
        #expect(savedRelaunchSession == nil)
    }

    @Test
    func savingWhileInactiveWritesNothing() {
        makeController().saveSessionForRelaunch()
        #expect(savedRelaunchSession == nil)
    }

    private var savedRelaunchSession: Any? {
        defaults.object(forKey: AwakeController.relaunchSessionDefaultsKey)
    }

    /// Returns at once, advancing `clock` by the requested time.
    private var advancingSleep: AwakeController.Sleep {
        let clock = clock
        return { await clock.sleep(for: $0) }
    }

    /// The default sleep never finishes on its own, so expiry happens only when a test chooses `advancingSleep`.
    private func makeController(
        sleep: @escaping AwakeController.Sleep = { _ in try await Task.sleep(for: .seconds(3_600)) }
    ) -> AwakeController {
        let clock = clock
        return AwakeController(assertionClient: client, defaults: defaults, now: { clock.now }, sleep: sleep)
    }
}
