import Foundation

/// A single usage window (e.g. "5-hour messages", "monthly tokens").
public struct UsageMetric: Codable, Hashable {
    public let label: String
    public let used: Double
    public let limit: Double
    public let unit: String?
    public let resetDate: Date?
    public let windowLabel: String?

    /// How long this window is, when the provider says.
    ///
    /// Never inferred. The meter draws a pace notch at how far through the
    /// window we are, which is `resetDate` and this together; with a guessed
    /// duration the notch lands in a guessed place, and an instrument that is
    /// confidently wrong is worse than one that shows no mark at all. A metric
    /// without this gets a uniform track and no notch.
    public let windowDuration: TimeInterval?

    /// The stable series key for this window in the history store.
    ///
    /// The provider's own identifier ("five_hour", "weekly_scoped"); a
    /// normalised label is the fallback only where the provider gives none.
    /// It exists because keying the series on the displayed label is a
    /// data-loss bug: AIQuotaBar slugifies its label into the key, so the day a
    /// provider renames a window the series silently forks and every reading
    /// behind it is orphaned, with no key registry and no migration to put the
    /// two halves back together.
    public let windowKey: String?

    public init(
        label: String,
        used: Double,
        limit: Double,
        unit: String? = nil,
        resetDate: Date? = nil,
        windowLabel: String? = nil,
        windowDuration: TimeInterval? = nil,
        windowKey: String? = nil
    ) {
        self.label = label
        self.used = used
        self.limit = limit
        self.unit = unit
        self.resetDate = resetDate
        self.windowLabel = windowLabel
        self.windowDuration = windowDuration
        self.windowKey = windowKey
    }

    /// Decoding is written out rather than synthesised so the additive fields
    /// are pinned to `decodeIfPresent` and stay that way. The snapshot store
    /// holds every provider's last reading in one file: a metric written before
    /// these keys existed has to decode, because a throw here costs the user
    /// every row rather than one field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            label: try container.decode(String.self, forKey: .label),
            used: try container.decode(Double.self, forKey: .used),
            limit: try container.decode(Double.self, forKey: .limit),
            unit: try container.decodeIfPresent(String.self, forKey: .unit),
            resetDate: try container.decodeIfPresent(Date.self, forKey: .resetDate),
            windowLabel: try container.decodeIfPresent(String.self, forKey: .windowLabel),
            windowDuration: try container.decodeIfPresent(TimeInterval.self, forKey: .windowDuration),
            windowKey: try container.decodeIfPresent(String.self, forKey: .windowKey)
        )
    }

    public var percent: Double {
        // A NaN or infinite figure from a provider must not reach the meter:
        // `min(NaN, 1.0)` is NaN, and `Int(NaN)` traps at the call sites.
        guard limit > 0, limit.isFinite, used.isFinite else { return 0 }
        return min(max(used / limit, 0), 1.0)
    }

    /// The same fraction with the ceiling taken off, for the one consumer that
    /// must not have it: the figure.
    ///
    /// A meter is a length inside a track and cannot draw past its own end, so
    /// `percent` clamps and every drawing reads it. A *number* has no end.
    /// Clamping before it reached the digits made 147% of a cap byte-identical
    /// to exactly 100% — same figure, same full bar, same square cap, the
    /// overage traceable only in the money on the caption line — and 147% with
    /// overage billing is the one reading in the panel a user most needs to see.
    /// `UsageFigure` already says in its own doc that it does not clamp, "a
    /// budget is a line you can keep walking past"; the caller clamped before it
    /// ever got there.
    ///
    /// Floored at zero and NaN-guarded exactly as `percent` is, for the same
    /// reason: `Int(NaN)` traps.
    public var rawPercent: Double {
        guard limit > 0, limit.isFinite, used.isFinite else { return 0 }
        return max(used / limit, 0)
    }

    public var displayUsed: String { Self.format(used) }
    public var displayLimit: String { Self.format(limit) }

    private static func format(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.1fk", value / 1_000)
        } else if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.1f", value)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case used
        case limit
        case unit
        case resetDate
        case windowLabel
        case windowDuration
        case windowKey
    }
}

public struct UsageData: Codable, Hashable {
    public let providerID: String
    public let fetchedAt: Date
    public let planName: String?
    public let primary: UsageMetric
    public let secondary: [UsageMetric]
    /// Which account this is, when the service says. With several subscriptions
    /// in one list, "Connected" leaves open the obvious question of connected
    /// as whom.
    public let accountLabel: String?
    public let rawJSON: String?

    /// What this account has spent, when the service reports money at all.
    ///
    /// Kept out of the metrics because a bill is not a quota: it carries a
    /// currency, a period and a confidence, and a figure aibars priced locally
    /// off a published rate card must not be able to sit in the same field as
    /// one the provider itself accounted for.
    public let spend: SpendReport?

    public init(
        providerID: String,
        fetchedAt: Date = Date(),
        planName: String? = nil,
        primary: UsageMetric,
        secondary: [UsageMetric] = [],
        accountLabel: String? = nil,
        rawJSON: String? = nil,
        spend: SpendReport? = nil
    ) {
        self.providerID = providerID
        self.fetchedAt = fetchedAt
        self.planName = planName
        self.primary = primary
        self.secondary = secondary
        self.accountLabel = accountLabel
        self.rawJSON = rawJSON
        self.spend = spend
    }

    /// Written out for the same reason as `UsageMetric`'s: `spend` arrived after
    /// the snapshot file did, and a stored reading that predates it must decode
    /// with no spend rather than fail and take the rest of the file with it.
    /// `secondary` is read the same way for the same reason: a reading with no
    /// extra windows is a reading, not a corrupt record.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            providerID: try container.decode(String.self, forKey: .providerID),
            fetchedAt: try container.decode(Date.self, forKey: .fetchedAt),
            planName: try container.decodeIfPresent(String.self, forKey: .planName),
            primary: try container.decode(UsageMetric.self, forKey: .primary),
            secondary: try container.decodeIfPresent([UsageMetric].self, forKey: .secondary) ?? [],
            accountLabel: try container.decodeIfPresent(String.self, forKey: .accountLabel),
            rawJSON: try container.decodeIfPresent(String.self, forKey: .rawJSON),
            spend: try container.decodeIfPresent(SpendReport.self, forKey: .spend)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case fetchedAt
        case planName
        case primary
        case secondary
        case accountLabel
        case rawJSON
        case spend
    }
}

/// Tidies the plan identifiers providers hand back.
///
/// These are internal tier names, not labels meant for people: Claude reports
/// `Default_Claude_Max_20X`, which is accurate and unreadable. The service's own
/// name is redundant next to its logo, so it comes off too.
public enum PlanName {
    public static func pretty(_ raw: String, service: String) -> String {
        var words = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        // Boilerplate that carries no information for the reader.
        let noise: Set<String> = ["default", "plan", "tier", "subscription"]
        let serviceWords = Set(service.lowercased().split(separator: " ").map(String.init))
        words = words.filter {
            let lower = $0.lowercased()
            return !noise.contains(lower) && !serviceWords.contains(lower)
        }
        guard !words.isEmpty else { return raw }

        return words
            .map { word -> String in
                // "20X" is a multiplier, not a word.
                if let digits = word.first, digits.isNumber, word.lowercased().hasSuffix("x") {
                    return word.dropLast() + "×"
                }
                // Leave things that are already deliberately cased (GPT, API).
                if word == word.uppercased() { return word }
                return word.capitalized
            }
            .joined(separator: " ")
    }
}

public enum ProviderError: LocalizedError {
    case notAuthenticated
    case sessionExpired
    /// A challenge, not a dead session: a Cloudflare interstitial, a captcha, a
    /// captive portal answering on the site's behalf.
    ///
    /// It exists because 401 and 403 were folded into `sessionExpired`, and the
    /// refresh loop answers an auth failure by discarding the credential — so a
    /// hotel wifi splash page cost the user a browser session that was
    /// perfectly good. claude.ai draws the line itself: a genuinely invalid
    /// session carries `account_session_invalid` in the body of its 403, and a
    /// bot-protection challenge does not.
    case blocked(String)
    case rateLimited
    case network(String)
    case parse(String)
    case unsupported
    case configuration(String)

    /// What a row says when it cannot report.
    ///
    /// A closed set of eight sentences we wrote, every one of them ≤ 34
    /// characters so it fits the panel's 278pt text column on one line. Two
    /// things are deliberately gone from it.
    ///
    /// The enum case name: "Network error: The endpoint did not respond" put a
    /// programmer's label in front of a sentence a user could already read.
    ///
    /// The associated value: `.network` and `.parse` interpolate whatever came
    /// back off the wire, so the panel printed two lines of truncated JSON on
    /// one row and a Cloudflare parameter name on another. The value has not
    /// gone anywhere — it moved to `diagnostic`, which the row hangs in its
    /// tooltip. No call site changes; the payload simply stops reaching the
    /// screen.
    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not connected"
        case .sessionExpired:   return "Session expired — sign in again"
        case .blocked:          return "Blocked by bot protection — will retry"
        case .rateLimited:      return "Rate limited — will retry"
        case .network:          return "No response — will retry"
        case .parse:            return "Unreadable response — will retry"
        case .unsupported:      return "Not supported on this plan"
        case .configuration:    return "Needs setup in Settings"
        }
    }

    /// The raw detail behind the sentence, for a tooltip and for a log.
    ///
    /// Already capped at 200 characters by `ProviderHTTP` before it ever gets
    /// here. Nothing draws it in the panel.
    public var diagnostic: String? {
        switch self {
        case .blocked(let msg), .network(let msg), .parse(let msg), .configuration(let msg):
            let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .notAuthenticated, .sessionExpired, .rateLimited, .unsupported:
            return nil
        }
    }

    /// Whether the credential itself is the problem. Callers discard a rejected
    /// credential on the strength of this, so `blocked` must stay out of it:
    /// the session may well be fine and the site simply is not answering us.
    public var isAuth: Bool {
        switch self {
        case .notAuthenticated, .sessionExpired: return true
        default: return false
        }
    }
}
