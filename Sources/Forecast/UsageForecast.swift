import Foundation

/// One reading of a usage meter, as a fraction of its cap.
public struct UsageSample: Codable, Hashable, Sendable {
    public let at: Date
    /// 0...1. Clamped here rather than trusted: a provider that reports 112%
    /// of a soft limit would otherwise put the forecast behind the cap it is
    /// meant to be predicting.
    public let percent: Double

    public init(at: Date, percent: Double) {
        self.at = at
        // A NaN loses every comparison it takes part in, so it would survive
        // `min`/`max` and then quietly poison the reset scan and the fit.
        self.percent = percent.isFinite ? min(max(percent, 0), 1) : 0
    }

    private enum CodingKeys: String, CodingKey {
        case at
        case percent
    }

    /// Samples are persisted between launches, and a file on disk is untrusted
    /// input like any other, so decoding goes through the clamping initialiser.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            at: try container.decode(Date.self, forKey: .at),
            percent: try container.decode(Double.self, forKey: .percent)
        )
    }
}

/// What the samples say happens next.
public enum Outcome: Equatable, Sendable {
    /// Not moving: nothing to project.
    case idle
    /// Going down — a rolling window shedding older messages, usually.
    case falling
    /// On pace to reach the cap at this date.
    case capsAt(Date)
    /// The window resets at this date, and at this pace the cap is not reached
    /// before it does.
    case resetsFirst(Date)
    /// Rising, but so slowly that the arrival date is further out than anything
    /// half an hour of samples can honestly claim.
    case beyondHorizon
}

public struct UsageProjection: Equatable, Sendable {
    public let outcome: Outcome
    /// Percentage points per hour. Positive is burning, negative is recovering.
    public let pointsPerHour: Double
    /// How many samples the fit used, after trimming.
    public let sampleCount: Int
    /// How much time those samples cover.
    public let span: TimeInterval

    /// Public so the copy below can be exercised against an outcome directly,
    /// without having to work backwards from it to a series that produces it.
    public init(outcome: Outcome, pointsPerHour: Double, sampleCount: Int, span: TimeInterval) {
        self.outcome = outcome
        self.pointsPerHour = pointsPerHour
        self.sampleCount = sampleCount
        self.span = span
    }
}

/// Burn rate and time-to-cap, as pure functions over samples.
///
/// The whole point of keeping this free of app state is that the awkward parts
/// — reset detection, the refusals, the wording — are the parts most worth
/// testing, and none of them need a running app to be wrong.
public enum UsageForecast {
    /// How far back the fit looks. Longer is steadier but slower to notice that
    /// someone has started working; half an hour is about where that trade sits.
    public static let window: TimeInterval = 30 * 60
    /// Recency weighting. A sample from ten minutes ago counts half as much as
    /// one from now, so a burst that has just started still moves the estimate.
    public static let halfLife: TimeInterval = 10 * 60
    public static let minimumSamples = 3
    public static let minimumSpan: TimeInterval = 5 * 60
    /// Nothing beyond this is claimed. Extrapolating half an hour of samples
    /// into tomorrow is arithmetic, not a forecast.
    public static let horizon: TimeInterval = 12 * 3600
    /// Older than this and the slope describes a session that has ended — the
    /// mac slept, or the user stopped — so it is not projected forward.
    public static let stalenessLimit: TimeInterval = 15 * 60
    /// A fall of twenty points in one step is a window rolling over, not usage
    /// going backwards. Everything before it belongs to the previous window.
    public static let resetDrop = 0.20

    /// Below this the slope is indistinguishable from noise, and dividing by it
    /// produces arrival dates in the next century.
    private static let epsilon = 0.05

    /// The samples the fit is allowed to see: inside the window, and after the
    /// most recent reset within it.
    public static func trimmed(_ samples: [UsageSample], now: Date) -> [UsageSample] {
        let recent = samples
            // A sample in the future is a clock that moved, and it would give
            // the fit a negative arm.
            .filter { $0.at <= now && now.timeIntervalSince($0.at) <= window }
            .sorted { $0.at < $1.at }

        var start = recent.startIndex
        for index in recent.indices.dropFirst()
        where recent[index - 1].percent - recent[index].percent >= resetDrop {
            start = index
        }
        return Array(recent[start...])
    }

    /// `nil` when the samples cannot support any statement at all. An outcome of
    /// `.idle`, `.falling` or `.beyondHorizon` is still a real answer — the burn
    /// rate is worth showing even when the arrival date is not.
    public static func project(_ samples: [UsageSample], now: Date, resetAt: Date?) -> UsageProjection? {
        let points = trimmed(samples, now: now)
        guard points.count >= minimumSamples,
              let first = points.first,
              let last = points.last else { return nil }

        let span = last.at.timeIntervalSince(first.at)
        guard span >= minimumSpan else { return nil }
        guard now.timeIntervalSince(last.at) <= stalenessLimit else { return nil }

        guard let slope = weightedSlope(points, origin: first.at, now: now) else { return nil }
        let pointsPerHour = slope * 3600 * 100

        func projection(_ outcome: Outcome) -> UsageProjection {
            UsageProjection(
                outcome: outcome,
                pointsPerHour: pointsPerHour,
                sampleCount: points.count,
                span: span
            )
        }

        guard pointsPerHour > epsilon else {
            return projection(pointsPerHour < -epsilon ? .falling : .idle)
        }

        // The slope comes from the fit, but the level comes from the last real
        // reading, so the arrival date agrees with the percentage on screen.
        let remaining = 1 - last.percent
        guard remaining > 0 else { return projection(.capsAt(last.at)) }
        let eta = last.at.addingTimeInterval(remaining / slope)

        // Checked before the horizon: a reset inside the next few hours is the
        // useful answer even when the arrival date it beats is days away.
        if let resetAt, resetAt > now, resetAt <= eta, resetAt.timeIntervalSince(now) <= horizon {
            return projection(.resetsFirst(resetAt))
        }
        guard eta.timeIntervalSince(now) <= horizon else { return projection(.beyondHorizon) }
        return projection(.capsAt(eta))
    }

    /// The full sentence, for the row. `nil` when there is nothing honest to say.
    ///
    /// - Parameter namesResetElsewhere: whether the line this sentence is going
    ///   onto already prints the reset. The `resetsFirst` sentence names it — it
    ///   is the whole of the good news — and the caption it rides on prints a
    ///   countdown for the same `resetDate` two runs earlier, so a row read
    ///   `resets in 25m · resets in 25m, you'll finish under`. Saying it twice is
    ///   worse than saying it once in either place, and the countdown is the one
    ///   to keep: it is a fact the provider published, where this is a claim
    ///   fitted from half an hour of samples. So the claim gives up the half of
    ///   itself that was already on the line and keeps the half only it can say.
    public static func phrase(
        for projection: UsageProjection,
        now: Date,
        namesResetElsewhere: Bool = false
    ) -> String? {
        switch projection.outcome {
        case .idle, .falling, .beyondHorizon:
            return nil
        case .capsAt(let date):
            guard date > now else { return nil }
            return "on pace to cap in \(duration(date.timeIntervalSince(now)))"
        case .resetsFirst(let date):
            guard date > now else { return nil }
            guard !namesResetElsewhere else { return "you'll finish under" }
            return "resets in \(duration(date.timeIntervalSince(now))), you'll finish under"
        }
    }

    /// The same answer for the one-line header, where there is room for the
    /// verdict but not the reasoning.
    public static func shortPhrase(for projection: UsageProjection, now: Date) -> String? {
        switch projection.outcome {
        case .idle, .falling, .beyondHorizon:
            return nil
        case .capsAt(let date):
            guard date > now else { return nil }
            return "caps in \(duration(date.timeIntervalSince(now)))"
        case .resetsFirst(let date):
            guard date > now else { return nil }
            return "won't cap before reset"
        }
    }

    // MARK: - Fit

    /// Recency-weighted least squares, in percent per second.
    ///
    /// Timestamps are mean-centred first. `Date` counts seconds from 2001, so
    /// the raw values are around 8e8 and squaring them in the normal equations
    /// throws away most of the mantissa before the slope is ever computed.
    private static func weightedSlope(_ points: [UsageSample], origin: Date, now: Date) -> Double? {
        var totalWeight = 0.0
        var weightedTime = 0.0
        var weightedPercent = 0.0
        var weights: [Double] = []
        var times: [Double] = []
        weights.reserveCapacity(points.count)
        times.reserveCapacity(points.count)

        for point in points {
            let weight = exp2(-now.timeIntervalSince(point.at) / halfLife)
            let time = point.at.timeIntervalSince(origin)
            weights.append(weight)
            times.append(time)
            totalWeight += weight
            weightedTime += weight * time
            weightedPercent += weight * point.percent
        }
        guard totalWeight > 0 else { return nil }

        let meanTime = weightedTime / totalWeight
        let meanPercent = weightedPercent / totalWeight

        var variance = 0.0
        var covariance = 0.0
        for (index, point) in points.enumerated() {
            let centred = times[index] - meanTime
            variance += weights[index] * centred * centred
            covariance += weights[index] * centred * (point.percent - meanPercent)
        }
        // Every sample landing on one instant leaves no slope to measure. The
        // span check should have caught it; this is what stops a divide by zero
        // if it ever does not.
        guard variance > 0 else { return nil }

        let slope = covariance / variance
        return slope.isFinite ? slope : nil
    }

    // MARK: - Copy

    /// Compact durations, rounded to the minute. Anything the caller sees here
    /// is inside the horizon, so hours are as coarse as it needs to go.
    private static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        guard minutes >= 1 else { return "under a minute" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(minutes)m" }
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}
