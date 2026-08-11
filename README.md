# aibars

A native macOS menu bar app that reads your usage out of eleven AI subscriptions — Claude, ChatGPT, Gemini, Grok, Perplexity, DeepSeek, Cursor, GitHub Copilot, OpenRouter, Mistral, and a generic JSON one — using the sessions already open in your browser. Swift and SwiftUI, no dependencies, macOS 13+, MIT.

Several apps do this. [How aibars compares](#how-this-compares) is further down, including the parts where the others are ahead.

```
   ▁▃▅▇   ← the menu bar: one bar per service, busiest first
╭──────────────────────────────────────────────────╮
│ ▁▃▅▇  AI Usage                       ↻   ⚙   ⏻   │
│       updated just now                           │
├──────────────────────────────────────────────────┤
│ (✳)  Claude   Max 20×                       92%  │
│      ███████████████████████████████████████░░   │
│      5h session                 resets in 1h 20m │
│      on pace to cap in 40m                       │
│      ▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂░░░░░░░░░░░░░░░░   │
│      Weekly · all models     resets in 2d 4h 61% │
│                                                  │
│ (◆)  Cursor   Pro                           64%  │
│      ███████████████████████████░░░░░░░░░░░░░░   │
│      320 / 500 reqs            resets in 11d 23h │
│                                                  │
│ (◍)  ChatGPT   Plus                              │
│      ● Subscription active         renews in 19d │
│                                                  │
│ ▸ NOT CONNECTED  7 ───────────────────────────── │
╰──────────────────────────────────────────────────╯
```

Everything in that panel is configurable, including how much of it is drawn: five presets and about thirty individual settings sit under Appearance, with a live preview.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/AndrxwWxng/aibars/main/install.sh | bash
```

That script builds aibars from source on your machine. It needs Xcode 16+ — the full Xcode, not just the command line tools — and [XcodeGen](https://github.com/yonaskolb/XcodeGen). There is no prebuilt binary to download, nothing is fetched but this repository, and nothing is stripped or unquarantined behind your back.

Piping a script from the internet into bash is a reasonable thing to refuse. The same build, by hand:

```sh
git clone https://github.com/AndrxwWxng/aibars
cd aibars
brew install xcodegen
make run
```

`make run` generates the Xcode project, builds it and opens the app. `make` builds only, `make open` opens the project in Xcode if you would rather hit ⌘R yourself, `make test` runs the test suite, `make clean` removes the generated project and its build products.

Xcode 16 is the floor because XcodeGen 2.45 and later write the project in a format earlier versions cannot open. Xcode 16 itself needs macOS 14.5, so that is in practice the floor for *building* aibars. macOS 13 is the floor for *running* it, which matters only if someone hands you a build.

## It lives in the menu bar

There is no Dock icon and no main window. After launch the only sign of aibars is the small bar meter in your menu bar — click it for the panel above. Settings, refresh and quit are the three buttons in the panel's header; ⌘, opens Settings, ⌘R refreshes, ⌘Q quits.

If you can't find the icon, the menu bar is probably full: macOS hides items it has no room for. Widen it by quitting something else in the bar, or move aibars leftwards by ⌘-dragging it.

## What it reads

One row per account, not per service. If you are signed into the same service in two browser profiles, aibars finds both and shows them as separate rows (`claude` and `claude#2`); you can give each one a name in Settings → Services.

| Service | What the row shows | How it connects |
|---------|--------------------|-----------------|
| Claude | Every limit window the account publishes — 5h session, weekly across all models, weekly per model — as percentages with reset times, busiest first. Plan tier and organisation name. | `sessionKey` cookie, read from your browser |
| ChatGPT | Subscription status, plan and renewal date. No bar: the endpoint reachable with a browser session carries no message counts, and an invented denominator would be worse than saying nothing. | `__Secure-next-auth.session-token` cookie |
| Gemini | 5-hour and weekly windows as percentages, plus credits remaining in each. | Google `__Secure-1PSID` cookie |
| Grok | Queries and tokens left in the current window, free-tier lanes included. | `sso` cookie on grok.com |
| Perplexity | Credit pools — the subscription pool, bonus credits with their expiry, and purchased credits. | `__Secure-authjs.session-token` cookie |
| DeepSeek | Balance in your own currency, with granted and topped-up amounts underneath. | API key from platform.deepseek.com/api_keys; paste it once |
| Cursor | Requests used against the monthly cycle, per bucket. | `WorkosCursorSessionToken` cookie |
| Copilot | Seat state (Active or Paused), plan, and the quota reset date. Status only — the public endpoints expose no numeric usage. | GitHub token with `read:user, copilot`, generated on a pre-filled form |
| OpenRouter | Credit balance, the current key's limit and spend, and lifetime spend. | Key from openrouter.ai/settings/keys; paste the `sk-or-v1-…` value |
| Mistral | Month-to-date spend, the vibe quota as a percentage, balance and token counts. | auth.mistral.ai session cookie; if it isn't picked up, paste admin.mistral.ai's whole cookie header, because Mistral names the cookie after your project |
| MiniMax | Whatever your endpoint reports. It is the generic provider: point it at a JSON URL and it reads a `used`/`limit` pair out of it. | A usage endpoint URL and a bearer token |

Three response shapes are understood by the generic provider; they are written out above `MiniMaxUsageParser.parse`. Anything else reads as 0/0.

Rows that report a state rather than a quota (ChatGPT, Copilot) draw a status line instead of a bar, are never counted towards the menu bar meter, and are never forecast or alerted on. A service with no ceiling has nothing to run out of.

## Pace

Under the headline meter of a row, when there is something honest to say:

```
on pace to cap in 40m
resets in 25m, you'll finish under
```

The answer is always stated against the window's own reset, never as a bare clock time. "2:58 PM" with no date is the thing people complain about most in this category of app, and it is also the least useful form of the answer: what you want to know is whether the cap arrives before the window rolls over.

How it works: aibars keeps the last six hours of readings per account, fits a recency-weighted line through the last half hour of them (ten-minute half-life, so a burst that has just started still moves the estimate), and divides what is left of the cap by that slope. A drop of twenty points or more is treated as the window resetting, and everything before it is discarded, so a fresh 5-hour window is never projected off the last one's slope.

It refuses to answer more often than it answers, on purpose. Nothing is shown when there are fewer than three readings, when they span less than five minutes, when the newest is more than fifteen minutes old (the Mac slept, or you stopped working), when usage is flat or falling, or when the projected date is more than twelve hours out. A line drawn through one reading is not a forecast.

And it is an extrapolation, not a promise. It assumes you carry on at the rate of the last half hour. Stop for lunch and it goes quiet rather than counting down; open six tabs and it will be late.

The same projection, in a shorter form, also goes in the panel header — "caps in 40m" beside the busiest service. The line on the rows can be switched off in Settings → Alerts → Pace.

## Alerts

Off until you turn them on. Settings → Alerts has one switch, two thresholds (80% and 95% by default, in steps of five), and two options: whether the secondary windows — the weekly and per-model caps — get their own alerts, and whether a window coming back down is worth telling you about.

Three rules the implementation is strict about:

- **Edge-triggered, with hysteresis.** A level fires when it is crossed and then stays quiet until usage falls five points back below it. A service parked at 90% is announced once, not once a minute.
- **Per window.** The 5-hour window and the weekly cap arm separately. You can be warned about the short one while the long one is nowhere near.
- **Nothing fires on first sight.** Install at 92% and you get no alert, because that was not a crossing aibars watched happen. It seeds and waits.

The honest limit: notifications need permission you may refuse, and macOS may not give this build permission at all. aibars is ad-hoc signed and un-notarised, so `UNUserNotificationCenter` sometimes declines to serve it. Two things follow from that. The permission is requested at the moment you turn alerts on, and a refusal is recorded rather than asked about again. The one case it is retried is the one where macOS never put a prompt on screen at all: that is not you saying no, so it is tried once more the next time the app starts with alerts already on. And every alert is written to a short log in the Alerts pane, marked delivered or not delivered, so a quiet menu bar can be told apart from a quiet Mac.

## Launch at login

Settings → General → Open aibars at login. Registered with macOS through `SMAppService`, which is the same list System Settings shows under General → Login Items — no launch agent is written and nothing is copied into `/Applications`, so moving or deleting the app undoes it.

Registration genuinely fails in the common case: run the app straight out of DerivedData or out of your Downloads folder and macOS refuses. The switch does not pretend otherwise. It asks, re-reads what the system actually did, and if that is not what you asked for it goes back to off with the reason underneath and a button into the right settings pane. Two states get their own line: macOS wanting you to approve the item by hand, and macOS refusing the copy of the app you are running.

## How this compares

What aibars does that the alternatives generally don't:

- **It reads each provider's own usage endpoint** using the session already sitting in your browser. There is no cookie to paste and no table of plan constants in the source to go stale — which is the failure mode that made every log-scraping tool in this niche start lying quietly the week a provider changed a limit. When a provider changes what it reports, the row changes with it.
- **Eleven services and several accounts per service**, discovered rather than configured. Two Claude logins in two browser profiles come up as two rows.
- **It answers the forward-looking question.** Most of these apps tell you where you are now. The pace line tells you whether the cap arrives before the window resets, stated as a duration against that reset, and says nothing at all when the samples can't support a claim.
- **It reads any browser you actually use** — Chromium and its forks, Firefox, Safari — rather than one.

Where the others are ahead, plainly:

- **AIUsageBar** covers far more services (around 47, including a great many coding agents and API dashboards) and tracks dollar spend across most of them. aibars shows money only where the provider itself reports it — DeepSeek, OpenRouter and Mistral — and has no budget feature.
- **AIQuotaBar** ships a WidgetKit desktop widget and a 90-day usage history window with a heatmap and per-day statistics. aibars has neither. There is no widget (it needs another target and is out of scope) and no history view; the sample ring behind the forecast holds six hours and is not something you can look at.
- Several of them read Claude Code's local stats file for a message count that needs no network at all. aibars does not.

And what none of us can fix: ChatGPT and Copilot do not expose numeric quota to any endpoint a browser session can reach, so nobody's percentage for those two is real. aibars shows a status line for them rather than a number.

## Connecting a service

Usually you don't. If you're already logged into a service in your browser, aibars adopts that session during the launch sweep and the row is connected before you touch anything.

When it can't, click **Sign in** on the row in the panel, or **Connect…** in Settings → Services. Both open the same window, and it handles every case, and it says which case you are in: a session found in three profiles and asking which account this is, a session found but locked behind the Keychain, a credential the service rejected, an account whose session quietly expired, a token you have to generate and paste. Login pages open in your own browser on the provider's own page; nothing is rendered inside aibars, because your password and your 2FA already live over there.

Copilot, DeepSeek and OpenRouter are the exceptions to hands-off capture: their APIs want a personal access token or API key rather than a session cookie, so aibars opens the right page and takes what it gives you.

Signing out clears aibars' copy of the credential and nothing else. Your browser session is left alone — clearing it would log you out of the website itself.

### Which browsers this works with

| Browser | Works | Notes |
|---------|-------|-------|
| Chrome, Edge, Brave, Arc, Chromium, Opera | Yes | Cookies are encrypted with a key in your login keychain. aibars asks for that key per browser, and only when you press Unlock in Settings → Services or in the connect window — a background sweep never raises the dialog. Decline and you can still paste a token. |
| Firefox | Yes | Cookies are stored in plaintext; nothing to unlock. |
| Safari | Needs Full Disk Access | Safari's cookies live in a TCC-protected container. The connect window offers a shortcut to the setting. |

Every connect window also takes a pasted token, so no browser is a hard requirement.

aibars ships unsandboxed. Reading Chromium's profile cookie databases, Safari's `~/Library/Cookies/Cookies.binarycookies` and the login keychain's Safe Storage items is not something the App Sandbox permits, so the entitlements file turns it off. The only other entitlement is the network client.

### What is stored, and where

Sessions read from a browser are held in memory only and re-derived at the next launch, which takes about half a second. They are deliberately never written to the Keychain: a locally signed build gets a new signature on every rebuild, so the old access control no longer matches and macOS would ask you to approve the item again every time. Having nothing to ask about is cheaper than answering.

Pasted API keys can't be re-derived from anything, so those do go in the Keychain — one item, `aibars.tokens`, read at most once per launch.

Everything else is UserDefaults: which services are enabled, your appearance settings, the alert rules and their armed state, and the six-hour sample rings behind the forecast. No usage data leaves your Mac, there is no server, no telemetry and no analytics.

## Settings

- **Services** — connect, sign out, name an account, show or hide a service, and a per-browser list of the sessions aibars can see with an Unlock button for the locked ones
- **Appearance** — five presets (Comfortable, Compact, Minimal, Dashboard, Monochrome) over sections for Size, What each row shows, Usage meter, The list and Menu bar, with a live preview and a Reset that puts everything back to how it shipped
- **Alerts** — the alert switch, both thresholds, the reset announcement, the pace line, macOS's permission state and the last five alerts with whether they were delivered
- **General** — launch at login, and the refresh interval: 30 seconds, 1, 5, 15 or 30 minutes
- **About** — version and links

The menu bar mark itself is under Appearance → Menu bar: icon only, icon plus the highest percentage, icon plus rotating service names, or percentage only, with one to six bars.

## Project layout

```
aibars/
├── install.sh                  builds from source and installs the app
├── project.yml                 XcodeGen config (3 targets: aibarsCore, aibars, aibarsTests)
├── Sources/                    aibarsCore framework
│   ├── Models/                 UsageData, UsageProvider protocol
│   ├── Auth/                   Keychain, cookie extractors, HTTP client, web login
│   ├── Brand/                  SVG path parser + provider logos
│   ├── Providers/              one file per service — see the table above
│   ├── Forecast/               burn rate and time-to-cap, and the sample ring behind it
│   ├── Notifications/          threshold policy (pure) and its delivery
│   ├── System/                 launch at login
│   ├── Views/                  SwiftUI views, connect window, settings window
│   └── AppState.swift          AppState (service registry, polling) + AnyUsageProvider
├── SourcesApp/                 aibars app target (thin wrapper)
│   ├── aibarsApp.swift         @main + MenuBarExtra scene
│   └── aibars.entitlements     Network client; sandbox off (reads browser cookie stores)
└── Tests/                      XCTest for parsers, policy, forecast and layout
```

The split exists so the app can ship with `@main` while unit tests run against the framework without bootstrapping the UI. The decisions worth testing are kept out of the views: `UsageForecast` and `ThresholdPolicy` are pure functions over samples and readings, with no app state, no I/O and no notification centre in them.

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
                // A limit of 0 means "no ceiling": the row draws a status line
                // instead of a bar, and is left out of the forecast and the alerts.
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

2. Register it in `AppState.services`: `Service(id: "myprovider") { AnyUsageProvider(MyProvider(accountID: $0)) }`. Nothing else is needed to make token entry, multi-account discovery, forecasting or alerts work — `AnyUsageProvider` dispatches through the protocol rather than switching on the id, and the sampling and the threshold policy both key off `id` and the metrics you return.
3. Give it a logo — either add a `BrandMark` entry in `Sources/Brand/BrandMarks.swift` (single-path SVG data plus its view box, 24×24 for simple-icons glyphs) or drop an image named `logo-myprovider` into an asset catalog. Without either, the row falls back to a lettermark in `accentColor`.
4. Add a test in `Tests/aibarsTests/ParserTests.swift`, against a real captured response with the identifying parts removed.

## Contributing

PRs welcome. Keep changes focused — one provider or one fix per PR. Run `make test` before submitting; the build is warning-free and should stay that way. See `CONTRIBUTING.md`.

Please don't commit any real session tokens or other secrets. `SECURITY.md` has the disclosure address.

## License

MIT — see `LICENSE`.

## Credits

Provider logos are single-path glyphs rendered at runtime by the small SVG path parser in `Sources/Brand/SVGPath.swift`. Most come from [simple-icons](https://github.com/simple-icons/simple-icons) and are used under [CC0-1.0](https://github.com/simple-icons/simple-icons/blob/develop/LICENSE.md). Two exceptions: the OpenAI mark is the glyph simple-icons published under CC0 up to v14, which was removed from that set in November 2025 pending brand permission, and the Grok mark comes from xAI's own brand assets and is not CC0 — it is reproduced only to identify the service, in its own shape, recoloured where a near-black mark would otherwise be invisible on a dark background. The logos remain trademarks of their respective owners and are used only to identify the service each row reports on. aibars is unofficial and is not affiliated with, endorsed by, or sponsored by any of these companies.

## Disclaimer

This is an unofficial project. Most of the usage endpoints aibars reads — Claude, ChatGPT, Gemini, Grok, Perplexity, Cursor, Copilot and Mistral — are not documented public APIs and may change or disappear without notice. Only DeepSeek's and OpenRouter's are documented. The generic provider reads whatever endpoint you point it at. aibars reads only what your own browser session has access to, with your own credentials, on the interval you set. Be a good citizen — don't hammer the endpoints.

## Roadmap

- ~~One-click auth (no more copy-paste)~~ — done, by handing off to your own browser rather than hosting a WebView
- ~~Chrome cookie decryption~~ — done
- ~~Burn rate and a predicted time-to-cap~~ — done
- ~~Warn before a cap is hit~~ — done
- ~~Launch at login~~ — done
- A history view: the forecast already keeps six hours of samples and throws them away, and there is no way to look at yesterday
- Per-window cost estimates in USD for the services that report money
- Not planned: a WidgetKit widget. It needs a separate target, and the menu bar is the point
