import Foundation
import Testing
@testable import RoastierKit

struct AwakeDurationTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let step: Int
        let interval: TimeInterval?
        let label: String

        var testDescription: String {
            "step \(step)"
        }
    }

    @Test(arguments: [
        Case(step: 0, interval: nil, label: "Indefinite"),
        Case(step: 1, interval: 300, label: "5 min"),
        Case(step: 12, interval: 3_600, label: "1 hr"),
        Case(step: 13, interval: 3_900, label: "1 hr 5 min"),
        Case(step: 144, interval: 43_200, label: "12 hr")
    ])
    func mapsStepToIntervalAndLabel(_ testCase: Case) {
        let duration = AwakeDuration(step: testCase.step)
        #expect(duration.timeInterval == testCase.interval)
        #expect(duration.label == testCase.label)
        #expect(duration.isIndefinite == (testCase.interval == nil))
    }

    @Test(arguments: [
        (-5, 0),
        (0, 0),
        (0.5, 1),
        (300, 1),
        (300.5, 2),
        (1_800, 6),
        (50_000, 144)
    ] as [(TimeInterval, Int)])
    func roundsIntervalUpToWholeStep(_ interval: TimeInterval, _ step: Int) {
        #expect(AwakeDuration(roundingUp: interval).step == step)
    }

    @Test
    func clampsOutOfRangeSteps() {
        #expect(AwakeDuration(step: -1) == .indefinite)
        #expect(AwakeDuration(step: 200).step == AwakeDuration.maxStep)
    }

    @Test
    func sliderStepsRunFromIndefiniteToMaxInIncreasingOrder() {
        let steps = AwakeDuration.sliderSteps
        #expect(steps.count == 33)
        #expect(steps.first == 0)
        #expect(steps.last == AwakeDuration.maxStep)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test(arguments: [
        (-1, "Indefinite"),
        (0, "Indefinite"),
        (1, "5 min"),
        (12, "1 hr"),
        (13, "1 hr 15 min"),
        (20, "3 hr"),
        (21, "3 hr 30 min"),
        (26, "6 hr"),
        (27, "7 hr"),
        (32, "12 hr"),
        (99, "12 hr")
    ] as [(Int, String)])
    func mapsSliderPositionToStop(_ position: Int, _ label: String) {
        #expect(AwakeDuration(sliderPosition: position).label == label)
    }

    @Test
    func sliderPositionRoundTripsThroughEveryStop() {
        for position in 0...AwakeDuration.maxSliderPosition {
            #expect(AwakeDuration(sliderPosition: position).sliderPosition == Double(position))
        }
    }

    @Test(arguments: [
        (39, 20.5),
        (75, 26.25),
        (78, 26.5)
    ] as [(Int, Double)])
    func interpolatesSliderPositionBetweenStops(_ step: Int, _ position: Double) {
        #expect(AwakeDuration(step: step).sliderPosition == position)
    }
}
