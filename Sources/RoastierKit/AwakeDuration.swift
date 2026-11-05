import Foundation

/// A duration in five-minute steps: step 0 is indefinite, up to 12 hours.
public struct AwakeDuration: Equatable, Sendable {
    public static let minutesPerStep = 5
    public static let maxStep = 144
    public static let indefinite = AwakeDuration(step: 0)
    static let stepInterval = TimeInterval(minutesPerStep * 60)

    /// The step at each slider position. Stops widen from five minutes to an hour as durations grow, so a 12-hour range
    /// doesn't crowd the track with steps too narrow to drag between.
    public static let sliderSteps = Array(0...12)
        + Array(stride(from: 15, through: 36, by: 3))
        + Array(stride(from: 42, through: 72, by: 6))
        + Array(stride(from: 84, through: maxStep, by: 12))

    public static let maxSliderPosition = sliderSteps.count - 1

    public let step: Int

    public init(step: Int) {
        self.step = min(max(step, 0), Self.maxStep)
    }

    public init(sliderPosition: Int) {
        self.init(step: Self.sliderSteps[min(max(sliderPosition, 0), Self.maxSliderPosition)])
    }

    /// The fewest steps covering `interval`; zero or less is indefinite.
    init(roundingUp interval: TimeInterval) {
        self.init(step: Int((interval / Self.stepInterval).rounded(.up)))
    }

    public var isIndefinite: Bool {
        step == 0
    }

    /// `nil` when indefinite.
    public var timeInterval: TimeInterval? {
        isIndefinite ? nil : TimeInterval(step) * Self.stepInterval
    }

    /// Fractional between stops, so a countdown through steps the slider can't stop at still moves the thumb smoothly.
    public var sliderPosition: Double {
        let upper = Self.sliderSteps.firstIndex { $0 >= step } ?? Self.maxSliderPosition
        guard upper > 0, Self.sliderSteps[upper] != step else {
            return Double(upper)
        }
        let lowerStep = Self.sliderSteps[upper - 1]
        return Double(upper - 1) + Double(step - lowerStep) / Double(Self.sliderSteps[upper] - lowerStep)
    }

    public var label: String {
        guard !isIndefinite else {
            return "Indefinite"
        }
        let minutes = step * Self.minutesPerStep
        let hours = minutes / 60
        let remainder = minutes % 60
        switch (hours, remainder) {
        case (0, _):
            return "\(remainder) min"
        case (_, 0):
            return "\(hours) hr"
        default:
            return "\(hours) hr \(remainder) min"
        }
    }
}
