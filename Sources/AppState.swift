import Foundation
import SwiftUI
import Combine

/// Central state for the menu bar app. Owns all provider instances,
/// drives the refresh loop, and surfaces the data the dropdown renders.
@MainActor
public final class AppState: ObservableObject {
    @Published public var providers: [AnyUsageProvider] = []
    @Published public var snapshots: [String: Result<UsageData, ProviderError>] = [:]
    @Published public var isRefreshing: Bool = false
    @Published public var lastRefresh: Date?
    @Published public var refreshIntervalSeconds: Int {
        didSet { userDefaults.set(refreshIntervalSeconds, forKey: intervalKey) }
    }
    @Published public var showInMenuBar: MenuBarDisplay {
        didSet { userDefaults.set(showInMenuBar.rawValue, forKey: displayKey) }
    }

    private let userDefaults = UserDefaults.standard
    private let intervalKey = "aibars.refreshInterval"
    private let displayKey = "aibars.menuBarDisplay"
    private var refreshTask: Task<Void, Never>?

    public enum MenuBarDisplay: String, CaseIterable, Identifiable {
        case iconOnly = "icon"
        case iconAndPercent = "percent"
        case iconAndName = "name"
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .iconOnly: return "Icon only"
            case .iconAndPercent: return "Icon + highest %"
            case .iconAndName: return "Icon + rotating names"
            }
        }
    }

    public init() {
        let stored = userDefaults.integer(forKey: intervalKey)
        self.refreshIntervalSeconds = stored == 0 ? 60 : stored
        let storedDisplay = userDefaults.string(forKey: displayKey).flatMap(MenuBarDisplay.init(rawValue:)) ?? .iconAndPercent
        self.showInMenuBar = storedDisplay

        self.providers = [
            AnyUsageProvider(ClaudeProvider()),
            AnyUsageProvider(ChatGPTProvider()),
            AnyUsageProvider(GoogleGeminiProvider()),
            AnyUsageProvider(GrokProvider()),
            AnyUsageProvider(PerplexityProvider()),
            AnyUsageProvider(DeepSeekProvider()),
            AnyUsageProvider(CursorProvider()),
            AnyUsageProvider(CopilotProvider()),
            AnyUsageProvider(MiniMaxProvider())
        ]
    }

    public func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                let interval = await self?.refreshIntervalSeconds ?? 60
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    public func refreshAll() async {
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = Date() }
        await withTaskGroup(of: (String, Result<UsageData, ProviderError>).self) { group in
            for provider in providers where provider.isEnabled {
                let id = provider.id
                group.addTask {
                    do {
                        let data = try await provider.fetchUsage()
                        return (id, .success(data))
                    } catch let e as ProviderError {
                        return (id, .failure(e))
                    } catch {
                        return (id, .failure(.network(error.localizedDescription)))
                    }
                }
            }
            for await (id, result) in group {
                snapshots[id] = result
            }
        }
    }

    /// Refreshes a single provider, for the per-row refresh button and for the
    /// moment right after a successful sign-in.
    public func refresh(_ providerID: String) async {
        guard let provider = provider(for: providerID) else { return }
        snapshots.removeValue(forKey: providerID)
        do {
            snapshots[providerID] = .success(try await provider.fetchUsage())
        } catch let error as ProviderError {
            snapshots[providerID] = .failure(error)
        } catch {
            snapshots[providerID] = .failure(.network(error.localizedDescription))
        }
    }

    public func provider(for id: String) -> AnyUsageProvider? {
        providers.first { $0.id == id }
    }

    /// Primary usage fraction for every enabled provider that reported
    /// successfully. Drives the menu bar meter.
    public var usageLevels: [Double] {
        providers
            .filter(\.isEnabled)
            .compactMap { provider in
                guard let snapshot = snapshots[provider.id],
                      let data = try? snapshot.get(),
                      // Status-only metrics (Copilot reports "active", not a
                      // quota) carry no usage and would otherwise read as 100%.
                      data.primary.limit > 0 else { return nil }
                return data.primary.percent
            }
    }

    /// Highest primary % across enabled, authenticated providers. Drives the
    /// menu bar badge.
    public var topUsagePercent: Double {
        usageLevels.max() ?? 0
    }

    /// Average of primary % across enabled providers. Used for icon color.
    public var averageUsagePercent: Double {
        let values = usageLevels
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Enabled providers in the order the dropdown should show them: the ones
    /// reporting real usage first and busiest-first within that, then status-only
    /// rows, then anything still loading or erroring, then the disconnected ones.
    /// Sorting by urgency means the row you need is always at the top.
    public var rankedProviders: [AnyUsageProvider] {
        providers
            .filter(\.isEnabled)
            .enumerated()
            .sorted { lhs, rhs in
                let a = rank(lhs.element), b = rank(rhs.element)
                if a.group != b.group { return a.group < b.group }
                if a.percent != b.percent { return a.percent > b.percent }
                // Declared order is the tiebreak, so rows don't shuffle
                // between refreshes.
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func rank(_ provider: AnyUsageProvider) -> (group: Int, percent: Double) {
        guard provider.isAuthenticated else { return (3, 0) }
        guard let snapshot = snapshots[provider.id] else { return (2, 0) }
        switch snapshot {
        case .success(let data):
            return data.primary.limit > 0 ? (0, data.primary.percent) : (1, 0)
        case .failure:
            return (2, 0)
        }
    }

    /// One line for the dropdown header — what the user would want to know
    /// without reading the whole list.
    public var headlineSummary: String {
        let connected = providers.filter { $0.isEnabled && $0.isAuthenticated }.count
        guard connected > 0 else { return "No services connected yet" }
        guard let name = topProviderName, let top = usageLevels.max() else {
            return "\(connected) connected · no quotas reported"
        }
        let percent = Int((top * 100).rounded())
        if top >= 0.85 { return "\(name) is nearly capped — \(percent)%" }
        return "\(name) highest at \(percent)%"
    }

    /// Display name of the provider currently closest to its cap.
    public var topProviderName: String? {
        let ranked = providers
            .filter(\.isEnabled)
            .compactMap { provider -> (String, Double)? in
                guard let snapshot = snapshots[provider.id],
                      let data = try? snapshot.get(),
                      data.primary.limit > 0 else { return nil }
                return (provider.displayName, data.primary.percent)
            }
            .sorted { $0.1 > $1.1 }
        return ranked.first?.0
    }
}

/// Type-erased wrapper so AppState can hold heterogeneous providers.
public final class AnyUsageProvider: ObservableObject, Identifiable {
    public let id: String
    public let displayName: String
    public let iconName: String
    public let accentColor: Color
    public let webLogin: WebLoginConfig?
    public let dashboardURL: URL?

    @Published public var isEnabled: Bool
    @Published public var isAuthenticated: Bool

    private let _fetch: () async throws -> UsageData
    private let _authenticate: () async throws -> Void
    private let _signOut: () async throws -> Void
    private let _setEnabled: (Bool) -> Void
    private let _saveToken: (String) throws -> Void
    private let _readAuthState: () -> Bool
    /// Only set for providers that need a user-supplied endpoint as well as a
    /// token (the generic JSON provider).
    private let _configure: ((String, String) -> Void)?
    private let _readEndpoint: (() -> String?)?

    public init<P: UsageProvider>(_ provider: P) where P: ObservableObject {
        self.id = provider.id
        self.displayName = provider.displayName
        self.iconName = provider.iconName
        self.accentColor = provider.accentColor
        self.webLogin = provider.webLogin
        self.dashboardURL = provider.dashboardURL
        self.isEnabled = provider.isEnabled
        self.isAuthenticated = provider.isAuthenticated
        self._fetch = { try await provider.fetchUsage() }
        self._authenticate = { try await provider.authenticate() }
        self._signOut = { try await provider.signOut() }
        self._setEnabled = { [weak provider] in provider?.setEnabled($0) }
        self._readAuthState = { [weak provider] in provider?.isAuthenticated ?? false }
        if let generic = provider as? MiniMaxProvider {
            self._configure = { [weak generic] endpoint, plan in
                generic?.configure(endpoint: endpoint, planName: plan)
            }
            self._readEndpoint = { [weak generic] in generic?.configuredEndpoint }
        } else {
            self._configure = nil
            self._readEndpoint = nil
        }
        self._saveToken = { token in
            switch provider.id {
            case "claude": try (provider as? ClaudeProvider)?.saveTokenManually(token)
            case "chatgpt": try (provider as? ChatGPTProvider)?.saveTokenManually(token)
            case "gemini": try (provider as? GoogleGeminiProvider)?.saveTokenManually(token)
            case "grok": try (provider as? GrokProvider)?.saveTokenManually(token)
            case "perplexity": try (provider as? PerplexityProvider)?.saveTokenManually(token)
            case "deepseek": try (provider as? DeepSeekProvider)?.saveTokenManually(token)
            case "cursor": try (provider as? CursorProvider)?.saveTokenManually(token)
            case "copilot": try (provider as? CopilotProvider)?.saveTokenManually(token)
            case "minimax": try (provider as? MiniMaxProvider)?.saveTokenManually(token)
            default: throw ProviderError.unsupported
            }
        }
    }

    public func fetchUsage() async throws -> UsageData {
        try await _fetch()
    }

    public func authenticate() async throws {
        try await _authenticate()
        await syncAuthState()
    }

    public func signOut() async throws {
        // Only aibars' own copy of the credential is dropped. The session lives
        // in the user's browser and is theirs — clearing it would silently log
        // them out of the website itself.
        try await _signOut()
        await syncAuthState()
    }

    public func setEnabled(_ enabled: Bool) {
        _setEnabled(enabled)
        isEnabled = enabled
    }

    public func saveTokenManually(_ token: String) throws {
        try _saveToken(token)
        // The save succeeded, so the credential exists regardless of when the
        // underlying provider gets around to flipping its own flag.
        Task { @MainActor in self.isAuthenticated = true }
    }

    /// True when the provider needs a usage endpoint configured alongside its
    /// token, rather than having one baked in.
    public var needsEndpointConfiguration: Bool { _configure != nil }

    public var configuredEndpoint: String? { _readEndpoint?() }

    public func configure(endpoint: String, planName: String) {
        _configure?(endpoint, planName)
    }

    /// The wrapper holds a snapshot of the underlying provider's auth flag, so
    /// it has to be pulled forward whenever the credential changes — otherwise
    /// rows keep showing "Sign in" after a successful login.
    @MainActor
    public func syncAuthState() async {
        isAuthenticated = _readAuthState()
    }
}
