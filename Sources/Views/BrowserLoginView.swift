import SwiftUI
import AppKit

/// Drives a sign-in that happens in the user's own browser.
///
/// aibars opens the provider's login page, then watches the browser's cookie
/// store until the session appears. Nothing is scraped and no page is rendered
/// in-app — the user logs in exactly where their passwords and 2FA already live.
@MainActor
public final class BrowserLoginCoordinator: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case waiting
        case found(browser: String)
        case verifying
        case failed(String)
        case done
    }

    @Published public private(set) var phase: Phase = .idle

    public let browser: DefaultBrowser
    private let provider: AnyUsageProvider
    private let config: WebLoginConfig
    private var pollTask: Task<Void, Never>?

    public init(provider: AnyUsageProvider, config: WebLoginConfig) {
        self.provider = provider
        self.config = config
        self.browser = DefaultBrowser.current()
    }

    /// Checks for a session that already exists before sending the user
    /// anywhere. Opening a login page for a service they're already logged into
    /// is the most annoying thing this window could do.
    public func begin() {
        guard config.expectedCookieName != nil, browser.supportsAutomaticCapture else {
            WebLoginEnvironment.openLoginPage(for: config)
            phase = .idle
            return
        }
        phase = .waiting
        Task { [weak self] in
            guard let self else { return }
            if await self.checkOnce() { return }
            WebLoginEnvironment.openLoginPage(for: config)
            self.startPolling()
        }
    }

    public func openLoginPageAgain() {
        WebLoginEnvironment.openLoginPage(for: config)
    }

    public func startPolling() {
        guard config.expectedCookieName != nil else { return }
        pollTask?.cancel()
        phase = .waiting
        pollTask = Task { [weak self] in
            // Ten minutes at a two-second cadence. Long enough for a password
            // manager, a 2FA code and a captcha; short enough not to poll a
            // forgotten window forever.
            for _ in 0..<300 {
                guard let self, !Task.isCancelled else { return }
                if await self.checkOnce() { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            self?.phase = .failed("Timed out waiting for a session. Paste a token instead.")
        }
    }

    /// A single look at the cookie stores. Also the "Check now" button.
    @discardableResult
    public func checkOnce() async -> Bool {
        guard let cookie = await WebLoginEnvironment.capturedCookie(
            for: config,
            preferring: browser.kind,
            // The user is sitting in front of a window they opened to sign in.
            allowingKeychainPrompt: true
        ) else {
            return false
        }
        phase = .found(browser: cookie.source.displayName)
        // Captured from a browser, so it's re-derivable and doesn't need storing.
        await save(cookie.value, source: .browserCookie)
        return true
    }

    public func save(_ value: String, source: SessionSource = .manualPaste) async {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        pollTask?.cancel()
        do {
            try provider.saveToken(token, source: source)
            phase = .verifying
            _ = try await provider.fetchUsage()
            phase = .done
        } catch {
            // The credential saved; only the usage call failed. Keep it — the
            // endpoint may just be temporarily unhappy — but say so.
            phase = .failed("Signed in, but the usage check failed: \(error.localizedDescription)")
        }
    }

    public func cancel() {
        pollTask?.cancel()
        pollTask = nil
    }
}

public struct BrowserLoginView: View {
    @StateObject private var coordinator: BrowserLoginCoordinator
    private let provider: AnyUsageProvider
    private let config: WebLoginConfig
    private let onFinish: (Bool) -> Void

    @State private var showsManualEntry: Bool
    @State private var pastedToken: String = ""

    public init(provider: AnyUsageProvider, config: WebLoginConfig, onFinish: @escaping (Bool) -> Void) {
        self.provider = provider
        self.config = config
        self.onFinish = onFinish
        self._coordinator = StateObject(
            wrappedValue: BrowserLoginCoordinator(provider: provider, config: config)
        )
        // Nothing to watch for in the PAT flow, so the field starts open.
        self._showsManualEntry = State(initialValue: config.expectedCookieName == nil)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline
            Divider().opacity(0.6)
            steps
            Divider().opacity(0.6)
            statusArea
        }
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            coordinator.begin()
            if !coordinator.browser.supportsAutomaticCapture {
                showsManualEntry = true
            }
        }
        .onDisappear { coordinator.cancel() }
        .onChange(of: coordinator.phase) { phase in
            if phase == .done {
                // Let the checkmark land before the window disappears.
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    onFinish(true)
                }
            }
        }
    }

    // MARK: - Sections

    private var headline: some View {
        HStack(spacing: 11) {
            ProviderLogo(
                providerID: provider.serviceID,
                fallbackName: provider.displayName,
                fallbackColor: provider.accentColor,
                size: 34
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in to \(provider.displayName)")
                    .font(.system(size: 14, weight: .semibold))
                Text(config.startURL.host ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepRow(number: 1, text: "aibars opened the login page in \(coordinator.browser.name).")
            StepRow(number: 2, text: config.expectedCookieName == nil
                    ? "Generate the token and copy it."
                    : "Log in there as you normally would.")
            StepRow(number: 3, text: config.expectedCookieName == nil
                    ? "Paste it below."
                    : "Come back here — aibars picks up the session on its own.")
        }
        .padding(16)
    }

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let limitation = coordinator.browser.limitation, config.expectedCookieName != nil {
                limitationBanner(limitation)
            } else {
                statusRow
            }

            if showsManualEntry {
                VStack(alignment: .leading, spacing: 6) {
                    Text(config.expectedCookieName.map { "Or paste “\($0)” manually" } ?? "Paste the token")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack {
                        SecureField("Token…", text: $pastedToken)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await coordinator.save(pastedToken) } }
                        Button("Save") { Task { await coordinator.save(pastedToken) } }
                            .disabled(pastedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Open page again") { coordinator.openLoginPageAgain() }
                    .buttonStyle(.link)
                if config.expectedCookieName != nil {
                    Button(showsManualEntry ? "Hide manual entry" : "Paste a token instead") {
                        withAnimation(.easeInOut(duration: 0.15)) { showsManualEntry.toggle() }
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                Button("Cancel") { coordinator.cancel(); onFinish(false) }
                    .keyboardShortcut(.cancelAction)
                if config.expectedCookieName != nil, coordinator.browser.supportsAutomaticCapture {
                    Button("Check now") { Task { await coordinator.checkOnce() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            switch coordinator.phase {
            case .idle:
                Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
                Text(config.hint).font(.system(size: 12)).foregroundStyle(.secondary)
            case .waiting:
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text("Waiting for your session…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            case .found(let browser):
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text("Found your session in \(browser).").font(.system(size: 12))
            case .verifying:
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text("Checking your usage…").font(.system(size: 12))
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Connected.").font(.system(size: 12, weight: .medium))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func limitationBanner(_ limitation: DefaultBrowser.Limitation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.orange)
                Text(limitation.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if limitation == .needsFullDiskAccess {
                HStack(spacing: 10) {
                    Button("Open Full Disk Access…") {
                        WebLoginEnvironment.openFullDiskAccessSettings()
                    }
                    .controlSize(.small)
                    Button("Try anyway") {
                        Task { await coordinator.checkOnce() }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Presents `BrowserLoginView` in its own small window — the menu bar dropdown
/// has no window of its own to hang a sheet from.
@MainActor
public enum LoginWindowController {
    private static var windows: [String: NSWindow] = [:]

    public static func show(provider: AnyUsageProvider, onFinish: @escaping (Bool) -> Void = { _ in }) {
        guard let config = provider.webLogin else { return }

        if let existing = windows[provider.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to \(provider.displayName)"
        window.isReleasedWhenClosed = false

        let view = BrowserLoginView(provider: provider, config: config) { success in
            close(provider.id)
            onFinish(success)
        }
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        // The banner and the manual entry field both change the content's
        // height, so let it size itself — and stay resizable, since a clipped
        // sign-in window would be unrecoverable.
        window.setContentSize(hosting.fittingSize)
        window.center()
        windows[provider.id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public static func close(_ providerID: String) {
        windows[providerID]?.close()
        windows[providerID] = nil
    }
}
