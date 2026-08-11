import Foundation

/// What the user asked to be told about.
///
/// Off until it is switched on. A menu bar app that starts sending system
/// notifications on the day it is installed is a menu bar app people uninstall,
/// and the whole point of aibars is that it sits still until it has something
/// to say.
public struct ThresholdRules: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Fractions of a cap, 0…1. Two by default: one warning with time left to
    /// change course, one that means it is about to stop working.
    public var levels: [Double]
    /// Whether the weekly and monthly caps get their own alerts, or only the
    /// window the menu bar shows.
    public var coversSecondaryWindows: Bool
    /// Whether the window coming back down is worth a notification too. Off,
    /// because "you can use it again" is news to almost nobody.
    public var announcesReset: Bool
    /// Minimum gap between two alerts for the same window, in seconds.
    public var cooldown: TimeInterval

    public init(
        isEnabled: Bool = false,
        levels: [Double] = [0.80, 0.95],
        coversSecondaryWindows: Bool = true,
        announcesReset: Bool = false,
        cooldown: TimeInterval = 1800
    ) {
        self.isEnabled = isEnabled
        self.levels = levels
        self.coversSecondaryWindows = coversSecondaryWindows
        self.announcesReset = announcesReset
        self.cooldown = cooldown
    }

    public static let `default` = ThresholdRules()

    /// Decoded field by field rather than by synthesis, so that adding a rule in
    /// a later version doesn't make every stored preference undecodable and
    /// silently reset the user's other choices along with it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ThresholdRules.default
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled)
            ?? fallback.isEnabled
        self.levels = try container.decodeIfPresent([Double].self, forKey: .levels)
            ?? fallback.levels
        self.coversSecondaryWindows = try container
            .decodeIfPresent(Bool.self, forKey: .coversSecondaryWindows)
            ?? fallback.coversSecondaryWindows
        self.announcesReset = try container.decodeIfPresent(Bool.self, forKey: .announcesReset)
            ?? fallback.announcesReset
        self.cooldown = try container.decodeIfPresent(TimeInterval.self, forKey: .cooldown)
            ?? fallback.cooldown
    }
}

/// What the policy remembers between readings.
///
/// Opaque on purpose: which levels are armed and when one last fired is an
/// implementation detail of the hysteresis, and nothing outside this file has a
/// reason to read or fabricate it. The caller's job is to persist it and hand
/// it back. If it ever fails to decode, an empty state is the safe fallback —
/// every window is then a first observation and seeds without firing, so a
/// corrupted file costs the user a missed alert rather than a burst of them.
public struct ThresholdState: Codable, Equatable, Sendable {
    fileprivate struct Entry: Codable, Equatable, Sendable {
        /// Held per entry rather than parsed back out of the key, so that a
        /// provider id containing the separator can't strand its own state.
        var providerID: String
        /// Levels that have already been reported and not yet fallen back far
        /// enough to rearm, in basis points. Integers because a Double round
        /// trip through JSON is not something set membership should depend on.
        var armed: [Int]
        var lastFiredAt: Date?
        /// The level of the last alert actually delivered, which is what an
        /// escalation is measured against.
        var lastFiredLevel: Int?
    }

    fileprivate var entries: [String: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
}

/// One notification the caller should post. Free of UserNotifications types so
/// the decision can be tested without a notification centre, an authorisation
/// prompt, or a bundle identifier.
public struct PendingAlert: Equatable, Sendable {
    /// Stable per provider and window. Reused as the request identifier so that
    /// a 95% banner replaces the 80% one still sitting in Notification Centre
    /// rather than stacking under it.
    public let key: String
    public let providerID: String
    public let title: String
    public let body: String
    public let at: Date
}

/// Decides which threshold alerts a reading has earned.
///
/// Three rules, all of them about silence rather than about noise:
///
/// - Edge-triggered with hysteresis. A level arms the moment it is crossed and
///   stays armed until the reading falls `hysteresis` back below it, so a
///   provider parked just over 90% is announced once and never again.
/// - Per window. The 5-hour window and the weekly cap arm separately, because
///   the people who want this feature want to know about the short window and
///   have already accepted the long one.
/// - Nothing fires on first sight. Installing at 92% is not a crossing aibars
///   witnessed, and claiming otherwise would train the user to ignore the next
///   one — which is the alert that would actually have helped.
public enum ThresholdPolicy {
    /// How far a reading has to fall back below a level before that level can
    /// fire again. Five points: wide enough to absorb providers whose figures
    /// wobble between polls, narrow enough that a genuine window reset always
    /// clears it.
    public static let hysteresis = 0.05

    /// Pure: same reading, same rules, same state, same answer. The caller keeps
    /// the returned state and hands it back next time.
    ///
    /// `providerID` is passed rather than read off `data` because it identifies
    /// the account, not the service — a second Claude subscription is "claude#2"
    /// while the payload it returns still says "claude", and the two accounts
    /// have to arm separately.
    public static func evaluate(
        _ data: UsageData,
        providerID: String,
        displayName: String,
        rules: ThresholdRules,
        state: ThresholdState,
        now: Date
    ) -> (alerts: [PendingAlert], state: ThresholdState) {
        let levels = resolvedLevels(rules)

        // Switched off is not the same as switched on and quiet: while nobody is
        // watching, nothing is remembered either. Otherwise turning the feature
        // back on after a week would compare today's reading against a stale
        // one and announce a crossing that happened unobserved.
        guard rules.isEnabled, !levels.isEmpty else {
            return ([], forget(providerID, in: state))
        }

        var next = state
        var alerts: [PendingAlert] = []
        var live: Set<String> = []
        let cooldown = max(0, rules.cooldown)

        for window in windows(in: data, providerID: providerID, rules: rules) {
            live.insert(window.key)
            let metric = window.metric
            let reading = basisPoints(metric.percent)

            guard var entry = next.entries[window.key] else {
                // Seed only. Everything already over the line counts as reported,
                // so the next alert is one that was watched happening.
                next.entries[window.key] = ThresholdState.Entry(
                    providerID: providerID,
                    armed: levels.filter { reading >= $0 },
                    lastFiredAt: nil,
                    lastFiredLevel: nil
                )
                continue
            }
            // Two providers can only ever collide on a key if one's id plus a
            // label spells out the other's; whoever reported last owns it, so
            // that `forget` at least stays right for the live one.
            entry.providerID = providerID

            // Levels the user has since removed drop out quietly — a change of
            // settings is not a window resetting.
            var armed = Set(entry.armed).intersection(levels)
            let wasArmed = !armed.isEmpty
            armed = armed.filter { reading > rearmPoint($0) }
            let fellBack = wasArmed && armed.isEmpty

            let crossed = levels.filter { reading >= $0 && !armed.contains($0) }
            armed.formUnion(crossed)

            if let top = crossed.max() {
                // The cooldown exists to stop repetition, not to hide an
                // escalation: a burn fast enough to clear 80% and 95% inside
                // half an hour is exactly the case the user wanted warning of.
                let escalates = entry.lastFiredLevel.map { top > $0 } ?? false
                let cooled = entry.lastFiredAt.map { now.timeIntervalSince($0) >= cooldown } ?? true
                if cooled || escalates {
                    alerts.append(PendingAlert(
                        key: window.key,
                        providerID: providerID,
                        title: "\(displayName) at \(percentText(metric))",
                        body: crossingBody(for: metric, now: now),
                        at: now
                    ))
                    entry.lastFiredAt = now
                    entry.lastFiredLevel = top
                }
                // A level suppressed by the cooldown still arms. The alternative
                // is delivering it later, out of date, once the reading has
                // moved on.
            } else if fellBack, rules.announcesReset {
                alerts.append(PendingAlert(
                    key: window.key,
                    providerID: providerID,
                    title: "\(displayName) reset",
                    body: resetBody(for: metric),
                    at: now
                ))
                // Deliberately not stamped as a fire: the reset can only happen
                // once per arming, so it needs no cooldown of its own, and
                // stamping it would mute the crossing that follows it.
            }

            // `lastFiredLevel` deliberately survives a disarm, while `armed`
            // does not. Clearing it here made `escalates` unanswerable after a
            // window rolled over, so a fresh window burned to 95% within the
            // cooldown of the previous window's 80% was silently swallowed —
            // the one crossing the feature exists to report. Kept, the two
            // cases separate correctly: the same level again is repetition and
            // stays suppressed, a higher one is an escalation and gets through.
            // The cooldown itself is what ages the memory out.
            entry.armed = armed.sorted()
            next.entries[window.key] = entry
        }

        // A provider that stops reporting a window should not keep its arming
        // for ever; if it comes back it comes back as a first observation.
        for key in keys(of: providerID, in: next) where !live.contains(key) {
            next.entries[key] = nil
        }

        return (alerts, next)
    }

    /// Drops everything remembered about a provider. Used when an account is
    /// signed out or removed, so that signing back in later seeds afresh rather
    /// than firing against a reading from a previous session.
    public static func forget(_ providerID: String, in state: ThresholdState) -> ThresholdState {
        var next = state
        for key in keys(of: providerID, in: state) {
            next.entries[key] = nil
        }
        return next
    }

    private static func keys(of providerID: String, in state: ThresholdState) -> [String] {
        state.entries.filter { $0.value.providerID == providerID }.map(\.key)
    }

    // MARK: - Windows

    /// The windows worth watching, primary first.
    ///
    /// `label` is the identity, not `windowLabel`: providers use the latter for
    /// display asides like "every 2h" or "free tier", while the label is the
    /// window's name and is what stays the same between polls.
    private static func windows(
        in data: UsageData,
        providerID: String,
        rules: ThresholdRules
    ) -> [(key: String, metric: UsageMetric)] {
        var candidates = [data.primary]
        if rules.coversSecondaryWindows { candidates += data.secondary }

        var keys: Set<String> = []
        var out: [(key: String, metric: UsageMetric)] = []
        for metric in candidates {
            // No ceiling, no threshold. Copilot's "Active" and the figures
            // reported without a cap have nothing to cross.
            guard metric.limit > 0, metric.limit.isFinite, metric.used.isFinite else { continue }
            let key = key(providerID: providerID, label: metric.label)
            guard keys.insert(key).inserted else { continue }
            out.append((key, metric))
        }
        return out
    }

    /// Namespaced so the caller can hand it straight to the notification centre
    /// as a request identifier without colliding with anything else the app
    /// might post.
    private static func key(providerID: String, label: String) -> String {
        "threshold.\(providerID).\(label)"
    }

    // MARK: - Levels

    private static func resolvedLevels(_ rules: ThresholdRules) -> [Int] {
        var out: Set<Int> = []
        for level in rules.levels where level.isFinite && level > 0 && level <= 1 {
            out.insert(basisPoints(level))
        }
        return out.sorted()
    }

    /// Where a level rearms. Floored at zero so a level set below the hysteresis
    /// band is still capable of rearming instead of latching for ever.
    private static func rearmPoint(_ level: Int) -> Int {
        max(0, level - basisPoints(hysteresis))
    }

    private static func basisPoints(_ fraction: Double) -> Int {
        Int((fraction * 10_000).rounded())
    }

    // MARK: - Wording

    private static func percentText(_ metric: UsageMetric) -> String {
        "\(Int((metric.percent * 100).rounded()))%"
    }

    /// The title already carries the number, so the body names the window and
    /// the counts behind it — and repeats neither. A metric already expressed as
    /// a percentage has no counts worth printing: "82 of 100" says nothing the
    /// title didn't.
    private static func crossingBody(for metric: UsageMetric, now: Date) -> String {
        var parts: [String] = []
        if metric.unit == "%" || metric.limit == 100 {
            parts.append(metric.label)
        } else {
            let unit = metric.unit.map { " \($0)" } ?? ""
            parts.append("\(metric.label): \(metric.displayUsed) of \(metric.displayLimit)\(unit)")
        }
        if let reset = metric.resetDate, let countdown = Countdown.short(until: reset, from: now) {
            parts.append("resets in \(countdown)")
        }
        return parts.joined(separator: ", ")
    }

    private static func resetBody(for metric: UsageMetric) -> String {
        "\(metric.label) is back to \(percentText(metric))"
    }
}
