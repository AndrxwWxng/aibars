import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

final class ZZBisect: XCTestCase {
    @MainActor
    private func fittingHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @MainActor
    func testBisect() throws {
        let domain = "aibars.zzbisect"
        let store = try XCTUnwrap(UserDefaults(suiteName: domain))
        store.removePersistentDomain(forName: domain)
        let a = AppearanceSettings(store: store)
        a.apply(.dashboard)
        let width = CGFloat(a.panelWidth)
        let sample = SampleService.claude

        let provider = AnyUsageProvider(ClaudeProvider())
        provider.isAuthenticated = true
        let data = UsageData(
            providerID: provider.id, planName: sample.plan,
            primary: sample.primary, secondary: sample.secondary, accountLabel: sample.account
        )
        func real() -> some View {
            ProviderRow(provider: provider, result: .success(data), onSignIn: {},
                        appearance: a,
                        budgets: BudgetStore(store: store), trend: UsageTrendStore(store: store))
        }
        func report(_ label: String) {
            let p = fittingHeight(SampleRow(appearance: a, service: sample), width: width)
            let r = fittingHeight(real(), width: width)
            print("BISECT \(label): preview=\(p) real=\(r)")
        }
        report("dashboard")
        a.rowActions = .never;      report("no actions")
        a.rowActions = .always
        a.showsPlanNames = false;   report("no plan")
        a.showsPlanNames = true
        a.showsAccountLabels = false; report("no account")
        a.showsAccountLabels = true
        a.secondaryWindows = .hidden; report("no windows")
        a.secondaryWindows = .chips;  report("chips")
        a.secondaryWindows = .expanded
        a.secondaryWindowLimit = 1;   report("one window")
        a.secondaryWindowLimit = 2;   report("two windows")
        a.secondaryWindowLimit = 6
        a.showsCountdowns = false;    report("no countdown")
        a.showsCountdowns = true
        a.showsAmounts = false;       report("no amounts")
    }
}
