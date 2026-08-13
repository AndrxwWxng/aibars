import XCTest
import Foundation
@testable import aibarsCore

// Where this suite keeps its state, and the two rules about it.
//
// **One: no test writes to `UserDefaults.standard`, and none of them holds
// `AppearanceSettings.shared` long enough to change it.**
//
// Under `xctest` that domain is `com.apple.dt.xctest.tool` and not
// `dev.aibars.app` — this suite was never editing the shipped app's preferences,
// and saying otherwise would be the wrong reason to care. The right reason is
// that it is one persistent domain shared by every test in the process, every
// suite in the bundle, and every run on the machine, and that it survives
// between runs. `AppDefaults` carries the sample taken off this machine before
// the change: appearance keys, provider switches and session metadata left there
// by runs that finished months ago.
//
// The pattern that replaces is a save/restore in a `defer`, and it is not robust
// in the one way that matters. `defer` runs on a failed assertion and on a thrown
// error; it does not run when the process is killed — a cancelled `xcodebuild`, a
// timeout, a crash in another test — and that is exactly when a sweep is most
// likely to be part way through. `PanelWidthContractTests` walked `panelWidth`
// through 300, 356, 420 and 520 on the shared object, so an interrupted run left
// the key wherever the sweep stopped and every later run "restored" that value
// faithfully. It has bitten this suite: `PanelLayoutTests` records
// `testWidthIsFixed` measuring a 420pt panel after a snapshot harness was
// interrupted, and it bit an agent again during the four-stage overhaul.
//
// A scratch domain has no such window. There is nothing to put back, so there is
// no point in a test at which being killed leaves anything behind that another
// test can read.
//
// **Two: a scratch domain's name is stable.** That is `TestDomain`, below, and
// the reason is measured rather than tidy.
//
// `AppDefaults` is the same pair of rules for the three pieces of app state that
// have no `store:` parameter to hand a domain to.

/// Domain names that are stable across runs and still distinct within one.
///
/// **This is the half that was costing real money on the machine, and it is not
/// obvious.** Twelve fixtures in this suite spelled uniqueness as
/// `"aibars.<suite>.tests.\(label).\(UUID().uuidString)"` and cleaned up with
/// `removePersistentDomain(forName:)` in a teardown block. Every one of those
/// teardowns ran. It did not help: `removePersistentDomain` *empties* a domain,
/// it does not delete the file, so each call left a 4KB plist in
/// `~/Library/Preferences` under a name no later run would ever ask for again.
///
/// Measured before this changed: **37,455 stray plists, 153MB**, and enough
/// domains that `defaults domains` no longer returned. Every full run of the
/// suite added roughly two thousand more.
///
/// So uniqueness is per *name*, not per *run*. The first caller of a base name
/// gets it; a second caller in the same process gets `.2`. Two stores that have
/// to coexist inside one test still get separate domains — `AlertCenterTests`
/// and `BudgetPaneTests` both need that — and the set of files the suite can
/// ever create is bounded by the number of fixtures rather than by the number of
/// times anybody has run it.
enum TestDomain {
    private static let lock = NSLock()
    private static var issued: [String: Int] = [:]

    /// Every domain this suite opens starts with this, so the litter from before
    /// the change is greppable and so any new litter is obviously ours:
    ///
    ///     ls ~/Library/Preferences | grep -c '^dev\.aibars\.test-scratch\.'
    static let prefix = "dev.aibars.test-scratch"

    static func stable(_ base: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let count = (issued[base] ?? 0) + 1
        issued[base] = count
        return count == 1 ? base : "\(base).\(count)"
    }
}

extension XCTestCase {

    /// An empty defaults domain named for the case that asked for it.
    ///
    /// Emptied on the way **in** as well as on the way out, and the entry wipe is
    /// the load-bearing one: `AppearanceSettings` decodes its whole snapshot in
    /// `init`, so a domain a killed run left behind would hand the next run that
    /// run's panel. The teardown wipe only keeps the plist count down.
    ///
    /// Named rather than a UUID, deliberately, and `TestDomain` above has the
    /// measurement: a fresh name per run leaves a plist nothing will ever ask for
    /// again, and thirty-seven thousand of them had accumulated.
    func isolatedStore(
        _ label: String = #function,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> UserDefaults {
        let sanitised = label
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "-")
        let domain = TestDomain.stable("\(TestDomain.prefix).\(type(of: self)).\(sanitised)")
        let store = try XCTUnwrap(
            UserDefaults(suiteName: domain),
            // Never a fallback to `.standard`. Three helpers in this suite used
            // to spell this `?? .standard`, which turns the one failure this
            // guard is for into the exact write it exists to prevent — silently,
            // on a green run.
            "could not open the scratch defaults domain \(domain)", file: file, line: line
        )
        store.removePersistentDomain(forName: domain)
        addTeardownBlock { store.removePersistentDomain(forName: domain) }
        return store
    }

    /// Appearance settings on a scratch domain: the shipped defaults, and nothing
    /// any other test or any earlier run has said about them.
    @MainActor
    func isolatedSettings(
        _ label: String = #function,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AppearanceSettings {
        AppearanceSettings(store: try isolatedStore("appearance.\(label)", file: file, line: line))
    }
}
