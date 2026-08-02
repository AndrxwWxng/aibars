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

    public func provider(for id: String) -> AnyUsageProvider? {
        providers.first { $0.id == id }
    }

    /// Highest primary % across enabled, authenticated providers. Drives the
    /// menu bar badge.
    public var topUsagePercent: Double {
        snapshots.values
            .compactMap { try? $0.get() }
            .map { $0.primary.percent }
            .max() ?? 0
    }

    /// Average of primary % across enabled providers. Used for icon color.
    public var averageUsagePercent: Double {
        let values = snapshots.values
            .compactMap { try? $0.get() }
            .map { $0.primary.percent }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

/// Type-erased wrapper so AppState can hold heterogeneous providers.
public final class AnyUsageProvider: ObservableObject, Identifiable {
    public let id: String
    public let displayName: String
    public let iconName: String
    public let accentColor: Color

    @Published public var isEnabled: Bool
    @Published public var isAuthenticated: Bool

    private let _fetch: () async throws -> UsageData
    private let _authenticate: () async throws -> Void
    private let _signOut: () async throws -> Void
    private let _setEnabled: (Bool) -> Void
    private let _saveToken: (String) throws -> Void

    public init<P: UsageProvider>(_ provider: P) where P: ObservableObject {
        self.id = provider.id
        self.displayName = provider.displayName
        self.iconName = provider.iconName
        self.accentColor = provider.accentColor
        self.isEnabled = provider.isEnabled
        self.isAuthenticated = provider.isAuthenticated
        self._fetch = { try await provider.fetchUsage() }
        self._authenticate = { try await provider.authenticate() }
        self._signOut = { try await provider.signOut() }
        self._setEnabled = { [weak provider] in provider?.isEnabled = $0 }
        self._saveToken = { token in
            switch provider.id {
            case "claude": try (provider as? ClaudeProvider)?.saveTokenManually(token)
            case "chatgpt": try (provider as? ChatGPTProvider)?.saveTokenManually(token)
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
    }

    public func signOut() async throws {
        try await _signOut()
    }

    public func setEnabled(_ enabled: Bool) {
        _setEnabled(enabled)
    }

    public func saveTokenManually(_ token: String) throws {
        try _saveToken(token)
    }
}
