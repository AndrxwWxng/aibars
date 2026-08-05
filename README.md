# aibars

A native macOS menu bar app that shows your usage across every AI subscription you pay for — Claude, ChatGPT, Cursor, GitHub Copilot, and anything else you can point it at.

```
   ▁▃▅▇  ← the menu bar, one bar per service
╭──────────────────────────────────────────╮
│ ▁▃▅▇  AI Usage                        ↻  │
│       Updated just now                   │
├──────────────────────────────────────────┤
│ (✳)  Claude  (Max)                   47% │
│      ██████████░░░░░░░░░░░░░░░░░░░░░░░░  │
│      5h window · resets in 3h 11m        │
│      ( 7d 11% )                          │
│                                          │
│ (◍)  ChatGPT  (Plus)                 85% │
│      ████████████████████████████████░░  │
│      34 / 40 msgs · resets in 1h 9m      │
│      ( GPT-4o 5/80 )                     │
│                                          │
│ (◆)  Cursor  (Pro)                   64% │
│      ████████████████████████░░░░░░░░░░  │
│      320 / 500 reqs · resets in 11d 23h  │
│                                          │
│ (◐)  GitHub Copilot  (Individual)        │
│      ● Active · renews in 19d            │
│                                          │
│ (◈)  MiniMax                  [ Sign in ]│
│      Not connected                       │
├──────────────────────────────────────────┤
│ ⚙ Settings                       ⏻ Quit  │
╰──────────────────────────────────────────╯
```

## Why

You probably pay for three or four AI tools and have no idea whether you're about to hit a cap. aibars puts every limit in one place, in your menu bar, and quietly refreshes in the background so you know what's left before you start a long task.

## Features

- **Menu bar meter** — one bar per service, tallest usage first, tinted red only when something is actually near its cap. Click for the dropdown.
- **Five providers out of the box**: Claude, ChatGPT, Cursor, GitHub Copilot, MiniMax — each with its own logo.
- **One-click sign-in** — aibars hosts the provider's real login page and picks up the session itself. No DevTools, no copy-paste.
- **Generic provider** — point at any JSON endpoint and aibars will display whatever it returns.
- **Refresh interval, display mode, enable/disable per provider** — all configurable in Settings.
- **Tokens stored in macOS Keychain**, never on disk.
- **Open source, MIT licensed**.

## Install (development)

Requirements: macOS 13+, Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone https://github.com/aibars/aibars
cd aibars
make
open aibars.xcodeproj
```

Then ⌘R in Xcode. The icon appears in your menu bar.

## Run from CLI

```sh
make run         # build + open
make test        # run XCTest
make clean       # nuke build artifacts
```

## Project layout

```
aibars/
├── project.yml                 XcodeGen config (3 targets: aibarsCore, aibars, aibarsTests)
├── Sources/                    aibarsCore framework
│   ├── Models/                 UsageData, UsageProvider protocol
│   ├── Auth/                   Keychain, cookie extractors, HTTP client, web login
│   ├── Brand/                  SVG path parser + provider logos
│   ├── Providers/              Claude, ChatGPT, Cursor, Copilot, MiniMax
│   └── Views/                  SwiftUI views, login window, settings window
├── SourcesApp/                 aibars app target (thin wrapper)
│   ├── aibarsApp.swift         @main + MenuBarExtra scene
│   └── aibars.entitlements     App sandbox + network client
└── Tests/                      XCTest for parsers
```

The split exists so the app can ship with `@main` while unit tests run against the framework without bootstrapping the UI.

## Sign in

Click **Sign in** on any row — in the dropdown or in Settings → Services. aibars opens that provider's own login page in a window, you log in the way you normally would, and the session is picked up and stored in the Keychain the moment it appears. The window closes itself.

| Provider    | What happens                                                                 |
|-------------|------------------------------------------------------------------------------|
| Claude      | claude.ai login → `sessionKey` captured automatically                        |
| ChatGPT     | chatgpt.com login → `__Secure-next-auth.session-token` captured automatically |
| Cursor      | cursor.com → WorkOS login → `WorkosCursorSessionToken` captured automatically |
| Copilot     | GitHub login → pre-filled token form; paste the token it shows you            |
| MiniMax     | Settings → **Configure…**: a usage endpoint URL and a bearer token            |

Copilot is the one exception to hands-off capture: its API wants a personal access token rather than a session cookie, so aibars drops you on GitHub's token page with the scopes pre-filled and takes the result in the same window.

Every login window also has a **Paste a token instead** link, and Settings still offers **Try browser cookies** for the manual providers — that reads an existing session out of Safari or Firefox. (Chrome cookies are encrypted with a Keychain key; the extractor returns metadata but not the value.)

Signing out clears the Keychain entry *and* the cookies aibars stored for that provider's domains, so the next sign-in starts clean.

## Settings

- **Refresh interval** — 30s, 1m, 5m, 15m, 30m
- **Menu bar mode** — meter only · meter + highest % · meter + busiest service name, with a live preview
- **Per-provider** — sign in / sign out, show or hide in the menu bar

## Adding a new provider

1. Create `Sources/Providers/MyProvider.swift`:

```swift
import Foundation
import SwiftUI

public final class MyProvider: ObservableObject, UsageProvider {
    public let id = "myprovider"
    public let displayName = "My Service"
    public let iconName = "star.fill"
    public let accentColor: Color = .orange

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false

    public init() {}

    public func fetchUsage() async throws -> UsageData {
        guard let token = SessionStore.shared.token(for: "myprovider") else {
            throw ProviderError.notAuthenticated
        }
        let (data, _) = try await ProviderHTTP(headers: [
            "Authorization": "Bearer \(token)"
        ]).get(URL(string: "https://api.example.com/usage")!)

        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return UsageData(
            providerID: "myprovider",
            planName: "Pro",
            primary: UsageMetric(
                label: "Requests",
                used: ProviderNumber.coerce(raw["used"]) ?? 0,
                limit: ProviderNumber.coerce(raw["limit"]) ?? 0,
                unit: "reqs"
            )
        )
    }

    /// Opt into one-click sign-in. Omit for manual token entry.
    public var webLogin: WebLoginConfig? {
        WebLoginConfig(
            startURL: URL(string: "https://example.com/login")!,
            capture: .cookie(name: "session", domainSuffix: "example.com"),
            hint: "Log in as usual — aibars picks up the session automatically.",
            dataDomains: ["example.com"]
        )
    }

    public func authenticate() async throws { /* cookie auto-detect */ }
    public func signOut() async throws { SessionStore.shared.clear("myprovider") }
    public func saveTokenManually(_ token: String) throws {
        try SessionStore.shared.setToken(token, for: "myprovider", source: .manualPaste)
    }
    public func setEnabled(_ enabled: Bool) { isEnabled = enabled }
}
```

2. Add `AnyUsageProvider(MyProvider())` to `AppState.providers`.
3. Add `case "myprovider": try (provider as? MyProvider)?.saveTokenManually(token)` in `AnyUsageProvider.init`.
4. Give it a logo — either add a `BrandMark` entry in `Sources/Brand/BrandMarks.swift` (single-path SVG data, 24×24 view box) or drop an image named `logo-myprovider` into an asset catalog. Without either, the row falls back to a lettermark in `accentColor`.
5. Add a test in `Tests/aibarsTests/ParserTests.swift`.

## Contributing

PRs welcome. Keep changes focused — one provider or one fix per PR. Run `make test` before submitting.

Please don't commit any real session tokens or other secrets.

## License

MIT — see `LICENSE`.

## Credits

Provider logos are the single-path glyphs from [simple-icons](https://github.com/simple-icons/simple-icons) (CC0), rendered at runtime by the small SVG path parser in `Sources/Brand/SVGPath.swift`. The logos themselves remain trademarks of their respective owners and are used only to identify the service each row reports on.

## Disclaimer

This is an unofficial project. The Claude, ChatGPT, Cursor, and Copilot usage endpoints are not documented public APIs and may change without notice. aibars reads only what your own browser session has access to, with your own credentials. Be a good citizen — don't hammer the endpoints.

## Roadmap

- ~~WebView-based auth (no more copy-paste)~~ — done
- Chrome cookie decryption
- Per-window cost estimates (USD)
- Notifications when a window is about to reset
- Today widget
