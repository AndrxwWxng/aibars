import Foundation
import SwiftUI

/// Tracks the GLM Coding Plan quotas on a Z.ai (Zhipu) subscription.
///
/// Auth: an inference API key from the Z.ai console, pasted by the user. Z.ai's
/// subscription pages sit behind a session aibars cannot reuse from a browser
/// cookie, and both endpoints below take the same bearer key the SDKs use, so a
/// pasted key is the whole story here.
///
/// Two routes, and only one of them is allowed to fail the refresh: the quota
/// route carries every meter, the subscription route carries only the plan name.
public final class ZaiProvider: ObservableObject, UsageProvider {
    public let id: String
    /// The account this instance follows, when a service is signed into more
    /// than once. Nil is the only-account case.
    public let accountID: String?
    public var serviceID: String { "zai" }
    public let displayName = "Z.ai"
    public let iconName = "z.square.fill"
    public let accentColor: Color = Color(red: 0.13, green: 0.53, blue: 0.93)

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false

    private let session = SessionStore.shared
    private let userDefaults = UserDefaults.standard
    private let enabledKey: String

    public init(accountID: String? = nil) {
        self.accountID = accountID
        self.id = accountID.map { "zai#\($0)" } ?? "zai"
        self.enabledKey = "aibars.\(self.id).enabled"
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.hasCredential(for: self.id)
            || Self.environmentToken(accountID: accountID, id: self.id) != nil
    }

    public var dashboardURL: URL? {
        URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")
    }

    public var webLogin: WebLoginConfig? {
        WebLoginConfig(
            // Signed out, this page bounces through the Z.ai login and lands
            // back here, so it is one destination for both states.
            startURL: URL(string: "https://z.ai/manage-apikey/apikey-list")!,
            capture: .tokenShownOnPage,
            hint: "Copy an API key from the list, then paste it below.",
            dataDomains: ["z.ai"]
        )
    }

    public func fetchUsage() async throws -> UsageData {
        guard let token = resolvedToken else {
            throw ProviderError.notAuthenticated
        }

        let headers = ["Authorization": "Bearer \(token)"]

        // Best-effort, and on the short timeout: this route only names the plan,
        // and a plan pill is not worth making the user wait 15s for the meters.
        let subscription = try? await Self.jsonObject(
            from: ProviderHTTP(headers: headers, timeout: 4),
            at: Self.subscriptionURL
        )

        do {
            let quota = try await Self.jsonObject(from: ProviderHTTP(headers: headers), at: Self.quotaURL)
            return try ZaiUsageParser.parse(quota, subscription: subscription)
        } catch let error as ProviderError {
            // A revoked key has to drop the flag, or the row keeps claiming it is
            // connected and never offers to paste a new one.
            if error.isAuth {
                await MainActor.run { self.isAuthenticated = false }
            }
            throw error
        }
    }

    public func authenticate() async throws {
        if resolvedToken != nil {
            await MainActor.run { self.isAuthenticated = true }
        }
    }

    public func signOut() async throws {
        session.clear(id)
        await MainActor.run { self.isAuthenticated = false }
    }

    public func saveTokenManually(_ token: String, source: SessionSource = .manualPaste) throws {
        // Keys are copied off a page that puts a newline after the value, and
        // whatever is stored goes into an Authorization header verbatim.
        try session.setToken(token.trimmingCharacters(in: .whitespacesAndNewlines), for: id, source: .apiKey)
        Task { @MainActor in self.isAuthenticated = true }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: enabledKey)
    }

    // MARK: - Endpoints

    /// Undocumented routes that Z.ai's own subscription pages call. There is no
    /// published usage API, and these are what the product itself reads.
    private static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    private static let subscriptionURL = URL(string: "https://api.z.ai/api/biz/subscription/list")!

    private static func jsonObject(from http: ProviderHTTP, at url: URL) async throws -> [String: Any] {
        let (data, _) = try await http.get(url)
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.parse("\(url.lastPathComponent) returned \(data.count) bytes that are not a JSON object")
        }
        return raw
    }

    // MARK: - Credential

    /// Trimmed on the way out as well as on the way in: keys stored by earlier
    /// builds kept whatever whitespace was pasted with them, and an all-blank
    /// value is not a credential.
    private var resolvedToken: String? {
        let stored = session.token(for: id) ?? Self.environmentToken(accountID: accountID, id: id)
        guard let token = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }
        return token
    }

    /// `ZAI_API_KEY` is what the current SDKs read and `GLM_API_KEY` is the
    /// Zhipu-era name they still accept, so a machine set up for either needs no
    /// setup here at all. Only the first account takes an environment key — a
    /// second one inheriting it would report the first account's numbers twice —
    /// and a deliberate sign-out outranks it, otherwise signing out would appear
    /// to do nothing.
    private static func environmentToken(accountID: String?, id: String) -> String? {
        guard accountID == nil, !AppState.signedOutProviders.contains(id) else { return nil }
        let environment = ProcessInfo.processInfo.environment
        for name in ["ZAI_API_KEY", "GLM_API_KEY"] {
            let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty { return value }
        }
        return nil
    }
}

public enum ZaiUsageParser {
    /// `quota` is GET /api/monitor/usage/quota/limit, `subscription` the
    /// best-effort GET /api/biz/subscription/list.
    ///
    /// The quota payload is a `limits` array under `data`, one entry per window:
    ///
    ///     data: { limits: [
    ///       { type: "TOKENS_LIMIT", unit: 3, number: 5,  percentage: 25, nextResetTime: 1770648402389 },
    ///       { type: "TOKENS_LIMIT", unit: 6, number: 1,  percentage: 61, nextResetTime: … },
    ///       { type: "TIME_LIMIT",   unit: 5, number: 1,  currentValue: 12, usage: 1000, nextResetTime: … }
    ///     ] }
    ///
    /// Each entry states its own window as a `(unit, number)` pair, which is why
    /// this is the one provider whose `windowDuration` needs no mapping table:
    /// the length is in the payload. It is also what tells the two token windows
    /// apart — a sub-daily one is the rolling session, a multi-day one is the
    /// week — so aibars never has to assume 5h and 7d are the plan's shape.
    ///
    /// The subscription payload is `data: [ { productName: "GLM Coding Max" } ]`.
    public static func parse(
        _ quota: [String: Any],
        subscription: [String: Any]? = nil
    ) throws -> UsageData {
        if let refusal = codingPlanRefusal(quota) {
            throw refusal
        }

        // `data` is the envelope in every payload seen, but an unwrapped body is
        // accepted too, since dropping the envelope is the cheapest way an
        // internal API like this changes shape. A `data` that is present and is
        // not an object is a response nobody should guess at.
        let container: [String: Any]
        if let data = quota["data"] {
            guard let object = data as? [String: Any] else {
                throw ProviderError.parse("Z.ai quota data is not an object")
            }
            container = object
        } else {
            container = quota
        }

        guard let limits = container["limits"] as? [[String: Any]] else {
            throw ProviderError.parse("No limits array in the Z.ai quota response")
        }

        var windows: [UsageMetric] = []
        for entry in limits {
            switch kind(of: entry) {
            case .tokens:
                switch windowLength(of: entry) {
                case .length(let duration):
                    windows.append(try tokenWindow(entry, duration: duration))
                case .unrecognisedUnit:
                    // Left out rather than guessed at: a future Z.ai window must
                    // not be able to hide the ones still understood, and without
                    // its length there is nothing to tell it apart by anyway.
                    continue
                case .missing:
                    throw ProviderError.parse("Z.ai token window has no window length")
                }
            case .time:
                windows.append(try webSearchWindow(entry))
            case .unknown:
                continue
            }
        }

        // Busiest first, so the headline figure is the limit actually at risk.
        let sorted = windows.sorted { $0.percent > $1.percent }
        guard let primary = sorted.first else {
            // An empty `limits` is a real state — a fresh plan that has metered
            // nothing yet — but a row needs a reading, and inventing a zero for
            // one would say the account has quota left when nothing said so.
            throw ProviderError.parse("Z.ai reported no usage windows")
        }

        return UsageData(
            providerID: "zai",
            planName: subscription.flatMap(planName),
            primary: primary,
            secondary: Array(sorted.dropFirst()),
            rawJSON: rawJSON(quota: quota, subscription: subscription)
        )
    }

    // MARK: - Windows

    private enum LimitKind {
        case tokens
        case time
        case unknown
    }

    /// The kind is in `type` on current payloads and was in `name` on older
    /// ones; both are checked because either can be the field that carries it.
    private static func kind(of entry: [String: Any]) -> LimitKind {
        for key in ["type", "name"] {
            guard let value = entry[key] as? String else { continue }
            if value == "TOKENS_LIMIT" { return .tokens }
            if value == "TIME_LIMIT" { return .time }
        }
        return .unknown
    }

    /// A token window, reported as a percentage rather than a token count.
    ///
    /// The label is only the window's name. Its length is on the metric itself,
    /// and a hand-written "5h" beside it would be a second copy of the same fact
    /// that can disagree with the first.
    private static func tokenWindow(_ entry: [String: Any], duration: TimeInterval) throws -> UsageMetric {
        guard let percentage = number(entry["percentage"]) else {
            // Missing usage is an invalid response, not a window sitting at zero.
            throw ProviderError.parse("Z.ai token window has no percentage")
        }
        return UsageMetric(
            label: duration < 24 * 3600 ? "Session" : "Weekly",
            used: min(max(percentage, 0), 100),
            limit: 100,
            unit: "%",
            resetDate: resetDate(entry),
            windowDuration: duration
        )
    }

    /// The monthly web-search, web-reader and Zread call count. A real count
    /// against a real ceiling, so it is the one Z.ai window with figures.
    ///
    /// `usage` is the ceiling and `currentValue` is what has been spent, which
    /// reads backwards and is worth stating: the field named for usage is the
    /// allowance.
    private static func webSearchWindow(_ entry: [String: Any]) throws -> UsageMetric {
        guard let used = number(entry["currentValue"]), used >= 0,
              let limit = number(entry["usage"]), limit >= 0 else {
            throw ProviderError.parse("Z.ai web search window has no usable count")
        }
        return UsageMetric(
            label: "Web search",
            used: used,
            limit: limit,
            unit: "searches",
            resetDate: resetDate(entry),
            // Optional here, unlike a token window: this entry is identified by
            // its type rather than by its length, so when the payload omits the
            // pair the row goes without a length rather than taking the 30 days
            // everyone assumes.
            windowDuration: windowLength(of: entry).duration
        )
    }

    /// What an entry's own `(unit, number)` pair says about its length.
    ///
    /// Three outcomes rather than an optional, because a token window needs to
    /// tell them apart: a pair aibars cannot read is a response to reject, and a
    /// unit it has never heard of is a window to leave out quietly.
    private enum WindowLength {
        case length(TimeInterval)
        case unrecognisedUnit
        case missing

        var duration: TimeInterval? {
            if case .length(let value) = self { return value }
            return nil
        }
    }

    /// `unit` is the calendar unit and `number` how many of them: (3, 5) is the
    /// five-hour session, (6, 1) the week, (5, 1) the web-search month. Matched
    /// as doubles rather than converted to Int, which traps on a value large
    /// enough to overflow.
    private static func windowLength(of entry: [String: Any]) -> WindowLength {
        guard let unit = number(entry["unit"]),
              let count = number(entry["number"]), count > 0 else {
            return .missing
        }
        let seconds: TimeInterval
        switch unit {
        case 3: seconds = 3600
        case 4: seconds = 24 * 3600
        case 5: seconds = 30 * 24 * 3600   // Z.ai bills a month as 30 days
        case 6: seconds = 7 * 24 * 3600
        default: return .unrecognisedUnit
        }
        let duration = seconds * count
        guard duration.isFinite, duration > 0 else { return .missing }
        return .length(duration)
    }

    /// `nextResetTime` arrives as epoch milliseconds (1770648402389), which is
    /// three orders of magnitude off every other provider in here and reads as a
    /// date in the year 58000 if taken as seconds.
    private static func resetDate(_ entry: [String: Any]) -> Date? {
        guard let milliseconds = number(entry["nextResetTime"]), milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    // MARK: - Plan

    /// The plan name off the first subscription that carries one, e.g.
    /// "GLM Coding Max". `PlanName.pretty` takes the trailing "Plan" off the
    /// longer product names, which the pill has no room for anyway.
    private static func planName(_ subscription: [String: Any]) -> String? {
        guard let list = subscription["data"] as? [[String: Any]] else { return nil }
        for entry in list {
            for key in ["productName", "product_name"] {
                if let name = entry[key] as? String, !name.isEmpty {
                    return PlanName.pretty(name, service: "Z.ai")
                }
            }
        }
        return nil
    }

    // MARK: - Internals

    /// A valid key on an account with no GLM Coding Plan: the quota route
    /// answers 2xx with `{"success":false,"code":500,"msg":"…coding plan…"}` and
    /// no `data` at all. Reported as configuration rather than parse failure
    /// because nothing is malformed — there is simply nothing metered yet, and
    /// the fix is a subscription rather than a bug report. Matched on the
    /// structured `success:false` as well as the phrase, so an unrelated
    /// business failure does not claim to know the cause.
    private static func codingPlanRefusal(_ quota: [String: Any]) -> ProviderError? {
        guard (quota["success"] as? Bool) == false else { return nil }
        let message = (quota["msg"] as? String) ?? ""
        guard message.lowercased().contains("coding plan") else { return nil }
        return ProviderError.configuration("No active GLM Coding Plan. Subscribe at z.ai/subscribe to see usage.")
    }

    /// A number, or nothing at all. `ProviderNumber.coerce` alone lets through
    /// two values that would put a figure nobody sent on screen: JSON `true`
    /// bridges to NSNumber and reads as 1, and `Double("nan")` succeeds — a NaN
    /// survives `percent` and reaches the meter's layout.
    private static func number(_ value: Any?) -> Double? {
        if let boxed = value as? NSNumber, CFGetTypeID(boxed) == CFBooleanGetTypeID() { return nil }
        guard let coerced = ProviderNumber.coerce(value), coerced.isFinite else { return nil }
        return coerced
    }

    /// `data(withJSONObject:)` raises an Objective-C exception rather than
    /// throwing for a value that is not JSON, and `parse` is public, so the
    /// payload is checked before it is encoded.
    private static func rawJSON(quota: [String: Any], subscription: [String: Any]?) -> String? {
        let payload: [String: Any] = ["quota": quota, "subscription": subscription ?? [:]]
        guard JSONSerialization.isValidJSONObject(payload) else { return nil }
        return try? JSONSerialization.data(withJSONObject: payload).base64EncodedString()
    }
}
