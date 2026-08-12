import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// Temporary. Renders one row in each of the six states so a human can look at
/// them. Deleted with the other snapshot harness.
final class ZZStatesSnapshot: XCTestCase {
    @MainActor
    func testWriteStatesSnapshot() throws {
        let state = AppState()
        let providers = Array(state.providers.prefix(6))
        guard providers.count == 6 else { return XCTFail("need six providers") }

        // 0 connected metered, 1 connected status-only, 2 loading,
        // 3 errored, 4 locked, 5 disconnected.
        var results: [Result<UsageData, ProviderError>?] = []
        results.append(.success(UsageData(
            providerID: providers[0].id, planName: "Max",
            primary: UsageMetric(label: "5h session", used: 92, limit: 100, unit: "%",
                                 resetDate: Date().addingTimeInterval(4_800)),
            secondary: [UsageMetric(label: "Weekly", used: 61, limit: 100, unit: "%")]
        )))
        results.append(.success(UsageData(
            providerID: providers[1].id, planName: "Pro",
            primary: UsageMetric(label: "Active", used: 0, limit: 0, unit: nil)
        )))
        results.append(nil)
        results.append(.failure(.network("the host is not answering")))
        results.append(.failure(.sessionExpired))
        results.append(nil)

        for (index, provider) in providers.enumerated() {
            provider.isAuthenticated = index != 5
        }

        let rows = VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(providers.enumerated()), id: \.offset) { index, provider in
                ProviderRow(provider: provider, result: results[index], onSignIn: {})
            }
        }
        .padding(.vertical, Tokens.Space.listMargin)
        .frame(width: 356)
        .background(Tokens.Surface.base)

        for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            let host = NSHostingView(rootView: AnyView(rows.environment(\.colorScheme, scheme)))
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            try data.write(to: URL(fileURLWithPath: "/tmp/aibars_states_\(name).png"))
            print("WROTE /tmp/aibars_states_\(name).png \(size.width)x\(size.height)")
        }
    }
}
