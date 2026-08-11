# aibars

A native macOS menu bar app that shows your usage across every AI subscription you pay for — Claude, ChatGPT, Cursor, GitHub Copilot, and anything else you can point it at.

```
   ▁▃▅▇  ← the menu bar: your busiest services, tallest first
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

- **Menu bar meter** — one bar for each of your busiest services, tallest usage first, tinted red only when something is actually near its cap. How many bars is up to you (1–6, four by default). Click for the dropdown.
- **Eleven providers out of the box**: Claude, ChatGPT, Gemini, Grok, Perplexity, DeepSeek, Cursor, GitHub Copilot, OpenRouter, Mistral, and MiniMax — each with its own logo.
- **Usually no sign-in at all** — if you're logged in in your browser, aibars adopts that session at launch. Otherwise one click opens the real login page in your default browser. No DevTools, no copy-paste.
- **Generic provider** — MiniMax is the generic one: point it at a JSON usage endpoint and aibars reads a `used`/`limit` pair out of it. Three response shapes are understood, listed above `MiniMaxUsageParser.parse`; anything else reads as 0/0.
- **Refresh interval, display mode, enable/disable per provider** — all configurable in Settings.
- **Nothing to store for most services** — a session read from your browser is kept in memory and re-derived at launch, so there is no credential on disk and no Keychain dialog. Pasted API keys, which can't be re-derived, go in the Keychain.
- **Open source, MIT licensed**.

## Install (development)

Requirements: macOS 13+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Xcode 16 is the floor because XcodeGen 2.45 and later write the project in a format earlier versions cannot open.

```sh
git clone https://github.com/AndrxwWxng/aibars
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
│   ├── Providers/              one file per service — see the table below
│   ├── Views/                  SwiftUI views, login window, settings window
│   └── AppState.swift          AppState (service registry, polling) + AnyUsageProvider
├── SourcesApp/                 aibars app target (thin wrapper)
│   ├── aibarsApp.swift         @main + MenuBarExtra scene
│   └── aibars.entitlements     Network client; sandbox off (reads browser cookie stores)
└── Tests/                      XCTest for parsers
```

The split exists so the app can ship with `@main` while unit tests run against the framework without bootstrapping the UI.

## Sign in

Usually you don't. If you're already logged into a service in your browser, aibars picks that session up at launch and the row is connected before you touch anything.

When you do need it, click **Sign in** on any row — in the dropdown or in Settings → Services. aibars opens that provider's own login page in your default browser, you log in the way you normally would, and the session is picked up the moment it appears.

Sessions read from a browser are held in memory only. They cost nothing to reproduce — the launch sweep takes about half a second — and storing them would mean a macOS Keychain dialog every time the app's signature changes, for no benefit. Only pasted API keys are written to the Keychain, because those can't be recovered any other way.

| Provider    | What happens                                                                     |
|-------------|----------------------------------------------------------------------------------|
| Claude      | claude.ai login → `sessionKey` captured automatically                            |
| ChatGPT     | chatgpt.com login → `__Secure-next-auth.session-token` captured automatically     |
| Gemini      | Google login → session cookies captured automatically                            |
| Grok        | grok.com → xAI login → `sso` captured automatically                              |
| Perplexity  | perplexity.ai login → Auth.js session cookie captured automatically              |
| DeepSeek    | platform.deepseek.com → API key; paste it once                                    |
| Cursor      | cursor.com → WorkOS login → `WorkosCursorSessionToken` captured automatically     |
| Copilot     | GitHub login → pre-filled token form; paste the token it shows you                |
| OpenRouter  | openrouter.ai/settings/keys → **Create Key**; paste the `sk-or-v1-…` value (shown once) |
| Mistral     | auth.mistral.ai login → session cookie captured automatically; if it isn't picked up, paste admin.mistral.ai's whole cookie header, because Mistral names the cookie after your project |
| MiniMax     | Settings → Services → **Connect…**: a usage endpoint URL and a bearer token       |

Copilot, DeepSeek and OpenRouter are the exceptions to hands-off capture: their APIs want a personal access token or API key rather than a session cookie, so aibars drops you on the right page and takes the result.

### Which browsers this works with

aibars reads the session out of the browser you logged in with, so that browser has to be one it can read:

| Browser                       | Works | Notes                                                          |
|-------------------------------|-------|----------------------------------------------------------------|
| Chrome, Edge, Brave, Arc, Opera | Yes   | macOS asks once for Keychain access to the browser's Safe Storage key. Decline and you can still paste a token. |
| Firefox                       | Yes   | Cookies are stored in plaintext; nothing to unlock.            |
| Safari                        | Needs Full Disk Access | Safari's cookies live in a TCC-protected container. The login window offers a shortcut to the setting. |

Every login window also has a **Paste a token instead** link, so no browser is a hard requirement.

aibars ships unsandboxed. Reading Chromium's profile cookie databases, Safari's `~/Library/Cookies/Cookies.binarycookies` and the login keychain's Safe Storage items is not something the App Sandbox permits, so the entitlements file turns it off.

Signing out clears aibars' copy of the credential only. Your browser session is left alone — clearing it would log you out of the website itself.

## Settings

- **Refresh interval** — 30 seconds, 1, 5, 15 or 30 minutes (General)
- **Appearance** — five presets (Comfortable, Compact, Minimal, Dashboard, Monochrome) over sections for Size, Rows, What each row shows, Usage meter, The list and Menu bar, with a live preview of the panel and a Reset that puts everything back to how it shipped
- **Menu bar mark** — Icon only · Icon + highest % · Icon + rotating names · Percentage only (Appearance → Menu bar)
- **Per-provider** — sign in / sign out, show or hide in the menu bar (Services)

## Adding a new provider

1. Create `Sources/Providers/MyProvider.swift`:

```swift
import Foundation
import SwiftUI

public final class MyProvider: ObservableObject, UsageProvider {
    /// Unique per account: "myprovider" for the only one, "myprovider#2" for a second.
    public let id: String
    public let accountID: String?
    public var serviceID: String { "myprovider" }
    public let displayName = "My Service"
    public let iconName = "star.fill"
    public let accentColor: Color = .orange

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false

    public init(accountID: String? = nil) {
        self.accountID = accountID
        self.id = accountID.map { "myprovider#\($0)" } ?? "myprovider"
    }

    public func fetchUsage() async throws -> UsageData {
        guard let token = SessionStore.shared.token(for: id) else {
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

    /// Where clicking through a connected row goes. Optional.
    public var dashboardURL: URL? { URL(string: "https://example.com/account/usage") }

    /// Opt into one-click sign-in. Omit for manual token entry.
    public var webLogin: WebLoginConfig? {
        WebLoginConfig(
            startURL: URL(string: "https://example.com/login")!,
            capture: .cookie(name: "session", domainSuffix: "example.com"),
            hint: "Log in as usual — aibars picks up the session automatically.",
            dataDomains: ["example.com"],
            // Only if the service writes more than one name — see Perplexity.
            alternateCookieNames: ["legacy-session"]
        )
    }

    public func authenticate() async throws { /* cookie auto-detect */ }
    public func signOut() async throws { SessionStore.shared.clear(id) }
    public func saveTokenManually(_ token: String, source: SessionSource = .manualPaste) throws {
        try SessionStore.shared.setToken(token, for: id, source: source)
    }
    public func setEnabled(_ enabled: Bool) { isEnabled = enabled }
}
```

2. Register it in `AppState.services`: `Service(id: "myprovider") { AnyUsageProvider(MyProvider(accountID: $0)) }`. Nothing else is needed to make token entry work — `AnyUsageProvider` dispatches `saveTokenManually` through the protocol rather than switching on the id.
3. Give it a logo — either add a `BrandMark` entry in `Sources/Brand/BrandMarks.swift` (single-path SVG data plus its view box, 24×24 for simple-icons glyphs) or drop an image named `logo-myprovider` into an asset catalog. Without either, the row falls back to a lettermark in `accentColor`.
4. Add a test in `Tests/aibarsTests/ParserTests.swift`.

## Contributing

PRs welcome. Keep changes focused — one provider or one fix per PR. Run `make test` before submitting.

Please don't commit any real session tokens or other secrets.

## License

MIT — see `LICENSE`.

## Credits

Provider logos are single-path glyphs rendered at runtime by the small SVG path parser in `Sources/Brand/SVGPath.swift`. Most come from [simple-icons](https://github.com/simple-icons/simple-icons) and are used under [CC0-1.0](https://github.com/simple-icons/simple-icons/blob/develop/LICENSE.md). Two exceptions: the OpenAI mark is the glyph simple-icons published under CC0 up to v14, which was removed from that set in November 2025 pending brand permission, and the Grok mark comes from xAI's own brand assets and is not CC0 — it is reproduced only to identify the service, in its own shape, recoloured where a near-black mark would otherwise be invisible on a dark background. The logos remain trademarks of their respective owners and are used only to identify the service each row reports on. aibars is unofficial and is not affiliated with, endorsed by, or sponsored by any of these companies.

## Disclaimer

This is an unofficial project. Most of the usage endpoints aibars reads — Claude, ChatGPT, Gemini, Grok, Perplexity, Cursor, Copilot and Mistral — are not documented public APIs and may change or disappear without notice. Only DeepSeek's and OpenRouter's are documented. The generic provider reads whatever endpoint you point it at. aibars reads only what your own browser session has access to, with your own credentials. Be a good citizen — don't hammer the endpoints.

## Roadmap

- ~~One-click auth (no more copy-paste)~~ — done, by handing off to your own browser rather than hosting a WebView
- ~~Chrome cookie decryption~~ — done
- Per-window cost estimates (USD)
- Notifications when a window is about to reset
- Today widget
