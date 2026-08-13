import Foundation

/// Whether this process is a real `.app` that macOS will treat as an
/// application.
///
/// False under `xctest` and in any command line context. Two features
/// short-circuit on it and both would otherwise do something to the user's
/// machine that outlives the test run: `LoginItem` would register the test
/// runner as a login item, and `GlobalHotkey` would take a system-wide key
/// combination out of the user's hands for as long as the runner lived.
///
/// The signal is the bundle on disk rather than an environment variable, because
/// the environment belongs to whoever launched the process — a real user's login
/// item must not be switchable off by an exported variable, and neither must
/// their shortcut.
///
/// It lives here rather than inside either feature because it was written twice
/// once already: `LoginItem` had its own copy and the hotkey needed the same
/// question answered. Two copies of a guard is one copy that gets fixed.
public enum HostProcess {
    /// Resolved once. `Bundle.main` cannot change under a running process, and a
    /// guard consulted on every registration should not be re-deriving a path
    /// extension each time.
    public static let isAppBundle: Bool = {
        let bundle = Bundle.main
        return bundle.bundleURL.pathExtension == "app" && bundle.bundleIdentifier != nil
    }()
}
