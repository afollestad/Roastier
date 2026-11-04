import Foundation

/// A duration slider position: step 0 is indefinite, and each further step adds five minutes, up to 12 hours.
public struct AwakeDuration: Equatable, Sendable {
    public static let minutesPerStep = 5
    public static let maxStep = 144
    public static let indefinite = AwakeDuration(step: 0)
    static let stepInterval = TimeInterval(minutesPerStep * 60)

    public let step: Int

    public init(step: Int) {
        self.step = min(max(step, 0), Self.maxStep)
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
