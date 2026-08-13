import Foundation

/// The defaults domain the app writes state into when that state has no store it
/// can be handed one of.
///
/// `.standard` in the app; a domain belonging to this process under XCTest.
///
/// The reasoning is `KeychainStore.isTesting`'s, one layer up: **the test runner
/// must not be able to edit state that outlives it.** The Keychain half was
/// closed when every run started putting an "xctest wants to access key
/// dev.aibars.app" dialog on somebody's screen. The defaults half stayed open,
/// and it is the harder of the two to notice, because nothing appears on screen.
///
/// Be precise about which domain, because the honest version is worse than the
/// dramatic one. A unit-test bundle has no host app, so under `xctest`
/// `UserDefaults.standard` resolves to `com.apple.dt.xctest.tool` — not to
/// `dev.aibars.app`. Nothing here was overwriting the shipped app's preferences.
/// What it was doing is worse for a test suite: writing into **one persistent
/// domain shared by every test in the process, every suite in the bundle, and
/// every run on the machine, for ever**. Sampled off this machine before the
/// change, that domain held
///
///     aibars.appearance.panelWidth = 356      aibars.appearance.textScale = 1
///     aibars.appearance.colorRamp  = "usage"  aibars.appearance.showsRowSparkline = false
///     aibars.appearance.adoptedLookGeneration = 3
///     aibars.claude#96.enabled = true         aibars.claude#97.enabled = true
///     aibars.sessionMeta = <701 bytes>        aibars.signedOut = []
///
/// — the settings `PanelWidthContractTests` sweeps and puts back, the enabled
/// flags `MultiAccountTests` throws, the credential metadata `SignOutTests` and
/// `KeychainAccessTests` seed, and a look-generation stamp, all left behind by
/// runs that finished months ago. A run killed part way through a sweep leaves
/// its own value there, and the next run reads it: `PanelLayoutTests` records
/// the symptom — `testWidthIsFixed` measuring a 420pt panel after a snapshot
/// harness was interrupted.
///
/// Three pieces of state could not be moved off it by the tests themselves,
/// because they have no `store:` to be handed one: `SessionStore.shared`, whose
/// initialiser is private, and `AppState`'s two `nonisolated static` registers,
/// which have no instance to carry a parameter. Everything else that persists
/// already takes an injected store.
///
/// The signal is XCTest being linked into *this process* rather than an
/// environment variable, for the reason spelled out at `KeychainStore.isTesting`:
/// the environment is chosen by whoever launches the app, so a variable would
/// make a real user's state reroutable by a shell that had exported it. No
/// shipping target links XCTest.
/// Public, and only for one reason: `ClaudeCodeProvider.init` is public and takes
/// `userDefaults: UserDefaults = AppDefaults.current`, and Swift requires a
/// public declaration's default argument to be public too. Nothing outside
/// `aibarsCore` has any business calling this — the app target does not, and the
/// tests reach it through `@testable`.
public enum AppDefaults {
    private static let isTesting = NSClassFromString("XCTestCase") != nil

    /// Not `dev.aibars.tests`, which is the test bundle's own identifier —
    /// `UserDefaults(suiteName:)` answers nil for the current bundle id and the
    /// fallback would be the domain this exists to avoid.
    private static let scratchDomain = "dev.aibars.test-scratch"

    /// Wiped on first use rather than on the way out, because there is no "way
    /// out" to hook: the process can be killed at any point. Emptying on entry is
    /// what makes a run independent of the run before it, which is the property
    /// that matters — a domain left behind is inert until something reads it, and
    /// nothing reads this one but the next wipe.
    public static let current: UserDefaults = {
        guard isTesting, let scratch = UserDefaults(suiteName: scratchDomain) else {
            return .standard
        }
        scratch.removePersistentDomain(forName: scratchDomain)
        return scratch
    }()
}
