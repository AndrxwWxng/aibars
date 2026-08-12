import Foundation
import SwiftUI

/// Claude Code, read off this Mac.
///
/// The only provider with no network call and no credential. Claude Code
/// already writes a JSONL transcript per session under `~/.claude/projects`,
/// and every assistant turn in it carries the token counts the API returned, so
/// reading those files is the whole of it. It is the source that still works on
/// an aeroplane.
///
/// The reading itself belongs to `ClaudeCodeIndex`, which knows the log layout
/// and keeps the watermark that makes a gigabyte of transcripts affordable once
/// a minute. This type is the boundary: it decides when to ask, whether there
/// is anything to ask about, and what the answer looks like in a row.
///
/// What it will not do is invent a ceiling. Claude Code publishes no local
/// quota — the subscription limits belong to the account, and `ClaudeProvider`
/// is the thing that reads them — so every window here is a figure with a zero
/// limit, the same status-only shape Copilot uses. A meter would need a
/// denominator nobody on this machine has.
///
/// `webLogin` and `dashboardURL` keep the protocol's nil defaults: there is
/// nothing to log into, and no page anywhere that shows this.
public final class ClaudeCodeProvider: ObservableObject, UsageProvider {
    public let id: String
    /// Kept for symmetry with the rest of the fleet, which the service registry
    /// constructs uniformly. A second instance here would be a second config
    /// root rather than a second login.
    public let accountID: String?
    public var serviceID: String { "claudecode" }
    public let displayName = "Claude Code"
    public let iconName = "terminal"
    /// Claude's terracotta a shade deeper. Same brand, and the row wants to be
    /// told apart at a glance from the claude.ai one it sits next to.

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false

    private let root: URL
    private let index: ClaudeCodeIndex
    private let userDefaults: UserDefaults
    private let enabledKey: String

    /// `root` and `userDefaults` are injectable so a test can point the scan at
    /// a fixture tree and keep the index's watermark out of the user's own
    /// settings.
    ///
    /// The root comes from `ClaudeCodeScanner` rather than `ClaudeCodeIndex`,
    /// because that one honours `CLAUDE_CONFIG_DIR` — the person who has moved
    /// their Claude Code config is exactly the person whose logs are not in the
    /// default place.
    public init(
        accountID: String? = nil,
        root: URL = ClaudeCodeScanner.defaultRoot(),
        userDefaults: UserDefaults = .standard
    ) {
        self.accountID = accountID
        self.id = accountID.map { "claudecode#\($0)" } ?? "claudecode"
        self.root = root
        self.index = ClaudeCodeIndex(root: root, store: userDefaults)
        self.userDefaults = userDefaults
        self.enabledKey = "aibars.\(self.id).enabled"
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = Self.hasTranscripts(in: root)
    }

    /// Whether Claude Code has ever run on this Mac.
    ///
    /// There is no credential, so this is the whole of what "connected" can
    /// mean here: the log directory is there and something is in it. An empty
    /// one is a Claude Code that has never been used, and calling that
    /// connected leaves a permanently empty row in the panel.
    static func hasTranscripts(in directory: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        // Dot files do not count. A directory holding nothing but a `.DS_Store`
        // is still a Claude Code that has never run.
        return contents.contains { !$0.hasPrefix(".") }
    }

    public func fetchUsage() async throws -> UsageData {
        guard Self.hasTranscripts(in: root) else {
            await MainActor.run { self.isAuthenticated = false }
            throw ProviderError.notAuthenticated
        }

        // Detached and at utility, because a refresh is file work — the first
        // sweep of a large corpus reads up to its own byte budget — and every
        // other provider spends this time inside URLSession rather than on a
        // thread of ours. The index is `Sendable` and locks its own state, so
        // handing it over is safe by its own contract rather than by ours.
        let totals = try await Task.detached(priority: .utility) { [index] in
            try index.refresh(now: Date())
        }.value

        await MainActor.run { self.isAuthenticated = true }
        return ClaudeCodeReport.data(providerID: id, totals: totals)
    }

    /// Nothing to authenticate against, so the only question is whether Claude
    /// Code has ever run here — asked again, so someone who installs it after
    /// aibars gets a working row without restarting the app.
    public func authenticate() async throws {
        let found = Self.hasTranscripts(in: root)
        await MainActor.run { self.isAuthenticated = found }
        guard found else {
            throw ProviderError.configuration(
                "No Claude Code sessions found in \(root.path). Run claude once, then refresh."
            )
        }
    }

    /// There is no credential to clear, and the transcripts are the user's own
    /// history rather than anything aibars put there — deleting them to satisfy
    /// a button would be vandalism. Signing out of a local source can only mean
    /// stopping reading it, so that is what this does.
    public func signOut() async throws {
        await MainActor.run { self.setEnabled(false) }
    }

    /// No token exists that would change what this reads.
    public func saveTokenManually(_ token: String, source: SessionSource = .manualPaste) throws {
        throw ProviderError.unsupported
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: enabledKey)
    }
}

// MARK: - Shaping the row

/// Turns a scan of the local logs into the shape the panel reads.
///
/// Separate from the provider and free of the filesystem, so the decisions that
/// matter — which window leads, what carries a limit, what the money is worth —
/// can be tested against a handwritten `ClaudeCodeTotals`.
public enum ClaudeCodeReport {
    /// The rolling window the panel leads with, spelled the way the row will
    /// read it: `StatusLine` renders a metric with a unit and no ceiling as
    /// "45.0k tokens in the last 5h", which is the true sentence. A bar would
    /// have to pick a denominator to draw itself, and there is not one.
    private static let sessionLabel = "in the last 5h"

    public static func data(providerID: String, totals: ClaudeCodeTotals) -> UsageData {
        let primary = UsageMetric(
            label: sessionLabel,
            used: tokens(totals.sessionWindow),
            limit: 0,
            unit: "tokens",
            resetDate: nil,
            windowLabel: "5h"
        )

        // Three further windows, all uncapped for the same reason. The index
        // rolls week and month rather than aligning them to the calendar, so
        // they are named for their length and not for a period.
        let secondary = [
            UsageMetric(label: "Today", used: tokens(totals.today), limit: 0, unit: "tokens"),
            UsageMetric(label: "7 days", used: tokens(totals.week), limit: 0, unit: "tokens"),
            UsageMetric(label: "30 days", used: tokens(totals.month), limit: 0, unit: "tokens")
        ]

        return UsageData(
            providerID: providerID,
            planName: nil,
            primary: primary,
            secondary: secondary,
            rawJSON: rawJSON(totals),
            spend: spend(totals.month)
        )
    }

    /// What the row counts. Cache reads are in it: they are tokens the model
    /// actually processed, and leaving them out understates a long coding
    /// session by an order of magnitude.
    private static func tokens(_ bucket: ClaudeCodeBucket) -> Double {
        Double(bucket.inputTokens)
            + Double(bucket.outputTokens)
            + Double(bucket.cacheCreationTokens)
            + Double(bucket.cacheReadTokens)
    }

    /// The dollar figure for the last thirty days, or nothing.
    ///
    /// `.estimated`, and it could not honestly be anything else: the tokens are
    /// measured but the money is those tokens priced at `ModelPricing`'s list
    /// rates, and a subscription does not charge list rates. Nil rather than
    /// zero when the index could not price a turn — a bill missing one model is
    /// not a smaller bill, and `estimatedUSD` already carries that distinction.
    ///
    /// `.rollingHours` rather than `.month`: the window slides with the day
    /// instead of resetting on the first, which is what `Period`'s calendar
    /// cases mean. There is no ceiling, because nobody publishes one for this.
    private static func spend(_ bucket: ClaudeCodeBucket) -> SpendReport? {
        guard let usd = bucket.estimatedUSD, usd.isFinite else { return nil }
        // `Int(_:)` traps outside its range, and the only thing that could put
        // a figure there is a corrupt token count. That is not a bill, so it
        // reports nothing rather than a number or a crash.
        let cents = (usd * 100).rounded()
        guard cents.magnitude < 9e15 else { return nil }
        return SpendReport(
            amountMinor: Int(cents),
            currency: "USD",
            exponent: 2,
            limitMinor: nil,
            period: .rollingHours(24 * 30),
            confidence: .estimated,
            resetDate: nil
        )
    }

    /// The per-model breakdown, base64-encoded JSON like every other provider's
    /// raw payload. It is the working that one dollar figure hides: which model
    /// spent what, how much of it was cache, and how old the rate card is that
    /// priced it.
    private static func rawJSON(_ totals: ClaudeCodeTotals) -> String? {
        let models = totals.byModel.mapValues { bucket -> [String: Any] in
            var entry: [String: Any] = [
                "turns": bucket.turns,
                "input": bucket.inputTokens,
                "output": bucket.outputTokens,
                "cache_creation": bucket.cacheCreationTokens,
                "cache_read": bucket.cacheReadTokens
            ]
            if let usd = bucket.estimatedUSD, usd.isFinite {
                entry["estimated_usd"] = usd
            }
            return entry
        }

        var payload: [String: Any] = [
            "source": "claude-code",
            "window": "30d",
            "priced_as_of": ModelPricing.asOf,
            "models": models
        ]
        if let last = totals.lastTurnAt {
            payload["last_turn_at"] = ProviderDate.iso8601.string(from: last)
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return data.base64EncodedString()
    }
}
