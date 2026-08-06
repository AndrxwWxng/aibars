import Foundation

/// A single usage window (e.g. "5-hour messages", "monthly tokens").
public struct UsageMetric: Codable, Hashable {
    public let label: String
    public let used: Double
    public let limit: Double
    public let unit: String?
    public let resetDate: Date?
    public let windowLabel: String?

    public init(
        label: String,
        used: Double,
        limit: Double,
        unit: String? = nil,
        resetDate: Date? = nil,
        windowLabel: String? = nil
    ) {
        self.label = label
        self.used = used
        self.limit = limit
        self.unit = unit
        self.resetDate = resetDate
        self.windowLabel = windowLabel
    }

    public var percent: Double {
        guard limit > 0 else { return 0 }
        return min(used / limit, 1.0)
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
}

public struct UsageData: Codable, Hashable {
    public let providerID: String
    public let fetchedAt: Date
    public let planName: String?
    public let primary: UsageMetric
    public let secondary: [UsageMetric]
    public let rawJSON: String?

    public init(
        providerID: String,
        fetchedAt: Date = Date(),
        planName: String? = nil,
        primary: UsageMetric,
        secondary: [UsageMetric] = [],
        rawJSON: String? = nil
    ) {
        self.providerID = providerID
        self.fetchedAt = fetchedAt
        self.planName = planName
        self.primary = primary
        self.secondary = secondary
        self.rawJSON = rawJSON
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
    case rateLimited
    case network(String)
    case parse(String)
    case unsupported
    case configuration(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in. Open Settings to authenticate."
        case .sessionExpired:   return "Session expired. Please re-authenticate."
        case .rateLimited:      return "Rate limited by the provider. Will retry."
        case .network(let msg): return "Network error: \(msg)"
        case .parse(let msg):   return "Could not parse response: \(msg)"
        case .unsupported:      return "This provider is not yet supported on your account type."
        case .configuration(let msg): return "Configuration error: \(msg)"
        }
    }

    public var isAuth: Bool {
        switch self {
        case .notAuthenticated, .sessionExpired: return true
        default: return false
        }
    }
}
