# aibars

A native macOS menu bar app that shows your usage across every AI subscription you pay for — Claude, ChatGPT, Cursor, GitHub Copilot, and anything else you can point it at.

```
╭─────────────────────────────────────╮
│ AI Usage          ↻                  │
├─────────────────────────────────────┤
│ ✦ Claude [Pro]                       │
│ ████████░░░░  47%  resets 3h 12m     │
│   7d window 11%                      │
│ 💬 ChatGPT [Plus]                    │
│ ████████████ 82%  GPT-5 24/40        │
│   GPT-4o 5/80                        │
│ ⌘ Cursor [Pro]                       │
│ █████░░░░░░░  320/500 reqs           │
├─────────────────────────────────────┤
│ Settings…                  Quit ⌘Q   │
╰─────────────────────────────────────╯
```

## Why

You probably pay for three or four AI tools and have no idea whether you're about to hit a cap. aibars puts every limit in one place, in your menu bar, and quietly refreshes in the background so you know what's left before you start a long task.

## Features

- **Menu bar widget** — single icon with the highest usage % in the status bar; click for a dropdown.
- **Five providers out of the box**: Claude, ChatGPT, Cursor, GitHub Copilot, MiniMax.
- **Pluggable auth** — sign in via browser cookies (Safari, Firefox) or paste a session token.
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
│   ├── Auth/                   Keychain, cookie extractors, HTTP client
│   ├── Providers/              Claude, ChatGPT, Cursor, Copilot, MiniMax
│   └── Views/                  SwiftUI views, settings window
├── SourcesApp/                 aibars app target (thin wrapper)
│   ├── aibarsApp.swift         @main + MenuBarExtra scene
│   └── aibars.entitlements     App sandbox + network client
└── Tests/                      XCTest for parsers
```

The split exists so the app can ship with `@main` while unit tests run against the framework without bootstrapping the UI.

## Sign in

aibars reads your session token from a browser cookie and falls back to a manual paste. For each provider:

| Provider    | Cookie name                              | Where to find it                                             |
|-------------|------------------------------------------|--------------------------------------------------------------|
| Claude      | `sessionKey`                             | claude.ai → DevTools → Application → Cookies                 |
| ChatGPT     | `__Secure-next-auth.session-token`       | chatgpt.com → DevTools → Application → Cookies               |
| Cursor      | `WorkosCursorSessionToken`               | cursor.com → DevTools → Application → Cookies                |
| Copilot     | _GitHub PAT_                             | Settings → Developer settings → PAT, `copilot` scope         |
| MiniMax     | _any bearer token_                       | Whatever you configured in Settings → MiniMax                |

Or click **Try browser cookies** in the auth sheet — if a matching cookie is in Safari or Firefox it'll be used automatically. (Chrome cookies are encrypted with a keychain key; the extractor returns metadata but not the value. Safari / Firefox work without extra permissions.)

## Settings

- **Refresh interval** — 30s, 1m, 5m, 15m, 30m
- **Menu bar mode** — icon only · icon + highest % · icon + rotating names
- **Per-provider** — sign in / sign out, enable / disable

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

    public func authenticate() async throws { /* cookie auto-detect */ }
    public func signOut() async throws { SessionStore.shared.clear("myprovider") }
    public func saveTokenManually(_ token: String) throws {
        try SessionStore.shared.setToken(token, for: "myprovider", source: .manualPaste)
    }
    public func setEnabled(_ enabled: Bool) { isEnabled = enabled }
}
```

2. Register the parser-instruction string in `Sources/Views/SettingsView.swift` (`AuthSheet.instructions`).
3. Add `AnyUsageProvider(MyProvider())` to `AppState.providers`.
4. Add `case "myprovider": try (provider as? MyProvider)?.saveTokenManually(token)` in `AnyUsageProvider.init`.
5. Add a test in `Tests/aibarsTests/ParserTests.swift`.

## Contributing

PRs welcome. Keep changes focused — one provider or one fix per PR. Run `make test` before submitting.

Please don't commit any real session tokens or other secrets.

## License

MIT — see `LICENSE`.

## Disclaimer

This is an unofficial project. The Claude, ChatGPT, Cursor, and Copilot usage endpoints are not documented public APIs and may change without notice. aibars reads only what your own browser session has access to, with your own credentials. Be a good citizen — don't hammer the endpoints.

## Roadmap

- WebView-based auth (no more copy-paste)
- Chrome cookie decryption
- Per-window cost estimates (USD)
- Notifications when a window is about to reset
- Today widget
