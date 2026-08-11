# aibars

A native macOS menu bar app that reads your usage out of fifteen AI services — Claude, Claude Code, ChatGPT, Codex, Gemini, Grok, Perplexity, DeepSeek, Cursor, GitHub Copilot, OpenRouter, Mistral, Z.ai, OpenCode, and a generic JSON one — using the sessions already open in your browser, or, for the two local sources, the files those tools already write on your Mac. Swift and SwiftUI, no dependencies, macOS 13+, MIT.

Several apps do this. [How aibars compares](#how-this-compares) is further down, including the parts where the others are ahead.

```
   ✳ 92  ◆ 64  ◍ —   the menu bar: a brand mark and its own figure per service
╭────────────────────────────────────────────────╮
│ ◈  AI USAGE                    ↻   ↗   ⚙   ⏻   │
│    updated 12s ago                             │
├────────────────────────────────────────────────┤
│▌✳  Claude  work  Max 20×                  92%  │
│    ███████████████████████▏█████░░░░░░░░░░░    │
│    5h session                resets in 1h 20m  │
│    on pace to cap in 40m                       │
│    ▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂░░░░░░░░░░░░░░    │
│    Weekly · all models     resets in 2d 4h 61% │
│                                                │
│ ◆  Cursor  Pro                            64%  │
│    ██████████████▏█████░░░░░░░░░░░░░░░░░░░░    │
│    320 / 500 reqs           resets in 11d 23h  │
│                                                │
│ ◍  ChatGPT  Plus                               │
│    ────────────────────────────────────────    │
│    ● Subscription active        renews in 19d  │
│                                                │
│ ▸ NOT CONNECTED  7 ─────────────────────────── │
╰────────────────────────────────────────────────╯
```

Two marks in there are the whole idea, and they are explained under [the bar with a slit in it](#the-bar-with-a-slit-in-it): the `▏` standing inside the fill is the reset clock, and the `▌` down the left edge of a row means that row wants you.

Everything in that panel is configurable, including how much of it is drawn: five presets and thirty individual settings sit under Appearance, with a live preview of a real row.

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

There is no Dock icon and no main window. After launch the only sign of aibars is a strip in your menu bar: one brand mark and its own figure per service, closest to its cap first, so you can tell which number is Claude's and which is Cursor's. Click it for the panel above.

The strip is disciplined about width, because it shares a 22pt bar with everyone else's status items:

- **Up to three services**, your choice of one, two or three under Appearance → Menu bar.
- **A reserved cell per figure**, three characters wide, sized once from the widest reading the strip can produce and never measured from the string in hand. A service crossing 99 into 100 does not widen the item and does not shove the icons to its left sideways.
- **A total cap of 148pt of drawing.** Over that, the least urgent segment is dropped until the item fits, because an item that keeps growing starts pushing other people's status items off a notched laptop.
- **A dash for a service that reports no quota.** ChatGPT reports a subscription and Copilot reports a seat; neither is a percentage, and an invented 0 reads as plenty left while an invented 100 reads as capped.

Two accounts of one service collapse to one segment in the strip — the busier of the two — because the same mark twice with two numbers reads as a rendering fault. The panel underneath is where accounts are told apart.

Refresh, history, settings and quit are the four buttons in the panel's header; ⌘R refreshes, ⌘, opens Settings, ⌘Q quits. The history button goes straight to the chart rather than to whichever pane Settings was last left on.

If you can't find the strip, the menu bar is probably full: macOS hides items it has no room for. Widen it by quitting something else in the bar, or move aibars leftwards by ⌘-dragging it.

## What it reads

One row per account, not per service. If you are signed into the same service in two browser profiles, aibars finds both and shows them as separate rows (`claude` and `claude#2`); you can give each one a name in Settings → Services.

| Service | What the row shows | How it connects |
|---------|--------------------|-----------------|
| Claude | Every limit window the account publishes — 5h session, weekly across all models, weekly per model — as percentages with reset times, busiest first. Plan tier and organisation name, and the extra-usage spend when overages are switched on. | `sessionKey` cookie, read from your browser |
| Claude Code | Read off this Mac, with no network call at all: tokens in the last 5 hours, then today, 7 days and 30 days, and an estimated dollar figure for the last thirty. None of it carries a ceiling, because nothing local publishes one. | Nothing to connect. Reads the session transcripts under `~/.claude/projects`, or wherever `CLAUDE_CONFIG_DIR` points |
| ChatGPT | Subscription status, plan and renewal date. No bar: the endpoint reachable with a browser session carries no message counts, and an invented denominator would be worse than saying nothing. | `__Secure-next-auth.session-token` cookie |
| Codex | The rolling windows OpenAI publishes for Codex itself — each with its own percentage, length and reset — the Spark limit where the account has one, and the flex-credit balance as money. | The ChatGPT session aibars already holds, the `codex` CLI's own login (`auth.json`, its keychain item as a fallback), or a pasted token. Tried in that order |
| Gemini | 5-hour and weekly windows as percentages, plus credits remaining in each. | Google `__Secure-1PSID` cookie; the whole SID family goes out on every request |
| Grok | Queries and tokens left in the current window, with the low- and high-effort counts underneath, and the free-usage gates instead where the account has no paid window. | `sso` cookie on grok.com |
| Perplexity | Credit pools — the subscription pool, bonus credits with their expiry, and purchased credits. | `__Secure-authjs.session-token` cookie, plus the three older names Perplexity still honours |
| DeepSeek | Balance in your own currency, with granted and topped-up amounts underneath. | API key from platform.deepseek.com/api_keys; paste it once |
| Cursor | Requests used against the monthly cycle, per bucket, and the on-demand spend run up this cycle. | `WorkosCursorSessionToken` cookie |
| Copilot | Seat state (Active or Paused), plan, and the quota reset date. Status only — the public endpoints expose no numeric usage. | GitHub token with `read:user, copilot`, generated on a pre-filled form |
| OpenRouter | Credit balance, the current key's limit and spend, and lifetime spend. Month to date also rides out as a spend figure a budget can be set against. | Key from openrouter.ai/settings/keys; paste the `sk-or-v1-…` value |
| Mistral | Month-to-date spend, the vibe quota as a percentage, balance and token counts. | auth.mistral.ai session cookie; if it isn't picked up, paste admin.mistral.ai's whole cookie header, because Mistral names the cookie after your project |
| Z.ai | The GLM Coding Plan's session and weekly token windows as percentages — each states its own length in the payload, so aibars never has to assume the plan's shape — and the monthly web-search count against its real ceiling. | An inference API key from the Z.ai console, or `ZAI_API_KEY` / `GLM_API_KEY` already in your environment |
| OpenCode | What this Mac spent through OpenCode's hosted gateways: Go's 5-hour, weekly and monthly caps against their published dollar limits, and the spend itself for today, yesterday and the last 30 days. | Nothing to connect. Reads `~/.local/share/opencode/opencode*.db`, honouring `OPENCODE_DATA_DIR` and `XDG_DATA_HOME` |
| MiniMax | Whatever your endpoint reports. It is the generic provider: point it at a JSON URL and it reads a `used`/`limit` pair out of it. | A usage endpoint URL and a bearer token |

Three response shapes are understood by the generic provider; they are written out above `MiniMaxUsageParser.parse`. Anything else reads as 0/0.

Rows that report a state rather than a quota — ChatGPT, Copilot, and every figure Claude Code reports — draw a status line instead of a bar, are never counted towards the menu bar strip, are not recorded in the history, and are never forecast or alerted on. A service with no ceiling has nothing to run out of, and a hairline where the bar would be says that out loud: "reports no quota" and "is at 0%" are different statements and the panel has to be able to make both.

The two local sources are honest about what they are. Claude Code's transcripts are the only place on the machine that says what the local agent has spent — the web endpoints know nothing about it — so those numbers are complete for this Mac and say nothing about another one. OpenCode is the same shape with a sharper edge: its caps are the published plan limits, which are facts about the product, but the numerator is only what this machine recorded, so a Go account also used from a second Mac reads low here. The row says "this Mac" for exactly that reason.

## The bar with a slit in it

Every usage window carries two quantities, and everyone else draws one. How much is spent is the first. How much of the *window* is spent is the second, and it is the one that decides whether 60% at lunchtime is fine or a problem.

aibars draws both, in one instrument:

- **the track is the reset clock.** The part of the window already gone is a shade heavier than the part remaining.
- **a riser stands at the boundary** — 1pt, running through the bar and a point or two proud of it.
- **when the fill overtakes the riser, the fill is cut.** A slit of the panel's own graphite is punched clean through the colour so the riser survives being drawn over, and the length of fill past the slit is exactly how far ahead of pace you are — read off the bar, with no number attached to it.

The riser is only ever drawn where the provider stated how long the window is. A mark on an inferred duration would be an inferred instrument, so a window nobody described gets a plain track and the row says what it knows in words instead. The slit needs a bar at least 5pt thick: the Compact preset's 4pt bar keeps the riser and drops the cut, because a gap as wide as the bar is tall reads as a broken bar rather than as a mark.

A row at or above the warning threshold says so four times over, and only one of the four is colour:

- **shape** — the fill's trailing end squares off,
- **weight** — the figure goes from medium to semibold,
- **the spine** — a 2pt bookmark at the row's leading edge, the only vertical coloured element in the panel,
- **colour** — last, and never load-bearing on its own.

Convert the panel to greyscale and the row is still identifiable. Set the ramp to Monochrome and it still is. The spine has exactly three reasons to appear — near a cap, needs you (locked, expired, or no credential), or the last request failed outright — and never a fourth, because a bookmark that appears for decoration stops meaning anything. The one thing the chrome never does is take an alarm colour: the row with the problem carries it, because a coloured edge across the header names no service and cannot be acted on.

The rest is deliberately quiet. Warm graphite surfaces with one material in the whole app, one teal that is aibars' own accent turned down, brand colour confined to the logo marks, and every number set in SF Mono inside a reserved, right-aligned column — so nothing on screen shifts as the digits tick, including on rows with no figure, rows still loading and rows that will never report one. Prose stays in SF Pro with tabular figures: "resets in 1h 20m" is a sentence, not a reading. Under Increase Contrast the rules, the riser and the spine all widen; under Reduce Transparency the one material is dropped rather than covered.

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

## History

Settings → History, or the chart button in the panel's header.

One usage window at a time — every account listed separately, since two logins to one service are spent at their own rates — over 24 hours, 7 days, 30 days or 90, drawn as a line on a 0–100% axis with the warning threshold marked. Hovering reads out the bucket under the pointer. Under the chart, one row per day: the day's peak, the mean of its readings, how many times the window crossed its cap, and how many readings the first two rest on, because a mean over two samples and a mean over two hundred are not the same claim.

What is kept, and for how long:

- **every reading, at the resolution it was taken, for 14 days.** Measured, a minute-by-minute fortnight is about 20,000 rows and 1 MB per series; a full panel settles around 20 MB and stays there.
- **one summary row per window per day, for 400 days** — longer than the readings behind it, so a year-over-year comparison has both ends of the year.

It lives in one SQLite file at `~/Library/Application Support/aibars/history.sqlite`. The schema is versioned and migrated on open, `UNIQUE(series, ts)` means two sweeps racing leave one row rather than two, and a window rolling over is written down as a boundary rather than clearing what came before it — clearing at a reset would throw away precisely what a history exists to show.

The limits worth knowing before relying on it:

- **Readings are only taken while aibars is running.** A gap in the chart is a Mac that was asleep, not a quiet day, which is why a day with nothing in it is missing from the table rather than shown as zero.
- **Ranges past 14 days are drawn from the daily summaries**, one point per day at that day's peak. The note under the chart says which grain you are looking at, rather than letting the retention policy pass for data.
- **Ratios, not counts.** History stores percentages on purpose, so a provider rewording its units or moving its cap mid-range cannot make an archived row unreadable. The CSV export carries the used and limit figures as well.
- **A series is keyed on its window, not on its label** — a normalised key, since no provider names its own windows yet. A genuine rewording still forks the series; that is as far as a derived key can honestly go, and it is still much better than keying on position, which files Monday's 5-hour window and Friday's weekly cap as one line.
- **No decimals in the table.** A tenth of a percent across a whole day is noise; hover a row for the precise peak and the reading count behind it.

Export CSV writes the range on screen, every window in it, at whichever grain survived. Clear History deletes every reading for every account, and recording carries on from the next refresh. Recording can be switched off, which leaves what is already stored — deleting is a different thing to want and should not happen as a side effect of a switch.

If the file cannot be opened at all — a full disk, a container the app cannot write — the pane says so and everything else carries on without it.

## Spend and budgets

Settings → Spend lists every service that reports money, what it says it has spent, and a cap you can set against it.

Four sources report money in a form a budget can be measured against: **Claude**'s extra-usage spend when overages are switched on, **Cursor**'s on-demand spend for the billing cycle, **OpenRouter**'s month to date, and **Claude Code**'s last thirty days. The first three are the provider's own accounting. The fourth is not: it is local token counts priced against a rate card typed into `ModelPricing` by hand, and it is marked `est.` wherever it appears — a subscription does not charge list rates, and if the index meets a model the table has no price for, the figure is withheld rather than reported smaller. A bill missing one model is not a smaller bill.

Money is held in minor units and an exponent, never a `Double`: a bill is an exact quantity, and a spend row that disagrees with the provider's own invoice by a cent is worse than no spend row at all.

What budgets do and do not do:

- **A cap changes nothing at the provider.** It is what aibars measures against, and warns you about.
- **One per service, plus one that covers everything.** Keyed by service rather than by account, because two Claude logins are one bill to the person paying.
- **One currency at a time.** There is no exchange rate in aibars and there is not going to be one — a rate means a network call, a cache, and a total that moves while you are reading it. Anything billed in another currency is named beside the total rather than folded into it, and a budget is never compared against spend in a different currency at all.
- **Two warning levels**, a fraction you set in steps of five and one at the cap itself. Each fires as it is crossed and not again, and nothing fires the first time aibars sees a budget: setting one while already over it is not a crossing it watched happen.
- **Going over is not clamped.** The meter fills past full and the row says how much over, rather than sitting at 100% and hiding exactly what the budget was set to find.

Where a budget is set and comparable, the row in the panel carries one extra line under everything the service itself reports: a thinner meter, "Budget", and how much is left or how far over. It is never the headline, because a quota is the service's number and a budget is yours.

The honest gaps. Money a provider reports as a metric but not as a bill — DeepSeek's balance, Mistral's month to date, Codex's credit balance, OpenCode's daily and 30-day spend — is shown on the row but cannot be budgeted, because it is not the same claim. Anthropic Console spend and Copilot organisation billing are real figures and are deliberately absent: they are org-level and API-account-level, not the subscription usage this app is about, and both need credentials aibars does not hold.

## Alerts

Off until you turn them on. Settings → Alerts has one switch, two thresholds (80% and 95% by default, in steps of five), and two options: whether the secondary windows — the weekly and per-model caps — get their own alerts, and whether a window coming back down is worth telling you about.

Three rules the implementation is strict about:

- **Edge-triggered, with hysteresis.** A level fires when it is crossed and then stays quiet until usage falls five points back below it. A service parked at 90% is announced once, not once a minute.
- **Per window.** The 5-hour window and the weekly cap arm separately. You can be warned about the short one while the long one is nowhere near.
- **Nothing fires on first sight.** Install at 92% and you get no alert, because that was not a crossing aibars watched happen. It seeds and waits.

Budget alerts are the same machinery pointed at a different number, with their own memory, so a spend crossing and a usage crossing cannot disarm each other.

The honest limit: notifications need permission you may refuse, and macOS may not give this build permission at all. aibars is ad-hoc signed and un-notarised, so `UNUserNotificationCenter` sometimes declines to serve it. Two things follow from that. The permission is requested at the moment you turn alerts on, and a refusal is recorded rather than asked about again. The one case it is retried is the one where macOS never put a prompt on screen at all: that is not you saying no, so it is tried once more the next time the app starts with alerts already on. And every alert is written to a five-line log in the Alerts pane, marked delivered or not delivered, so a quiet menu bar can be told apart from a quiet Mac.

## Launch at login

Settings → General → Open aibars at login. Registered with macOS through `SMAppService`, which is the same list System Settings shows under General → Login Items — no launch agent is written and nothing is copied into `/Applications`, so moving or deleting the app undoes it.

Registration genuinely fails in the common case: run the app straight out of DerivedData or out of your Downloads folder and macOS refuses. The switch does not pretend otherwise. It asks, re-reads what the system actually did, and if that is not what you asked for it goes back to off with the reason underneath and a button into the right settings pane. Two states get their own line: macOS wanting you to approve the item by hand, and macOS refusing the copy of the app you are running.

## How this compares

What aibars does that the alternatives generally don't:

- **The bar draws two quantities, not one.** The track behind the fill is the reset clock, the riser stands at the boundary, and the fill is cut where it has overtaken it. Nobody else's meter can say how far ahead of pace you are without a second number beside it.
- **It reads each provider's own usage endpoint** using the session already sitting in your browser. There is no cookie to paste and no table of plan constants in the source to go stale — which is the failure mode that made every log-scraping tool in this niche start lying quietly the week a provider changed a limit. When a provider changes what it reports, the row changes with it.
- **Fifteen services and several accounts per service**, discovered rather than configured. Two Claude logins in two browser profiles come up as two rows.
- **It answers the forward-looking question.** Most of these apps tell you where you are now. The pace line tells you whether the cap arrives before the window resets, stated as a duration against that reset, and says nothing at all when the samples can't support a claim.
- **It reads any browser you actually use** — Chromium and its forks, Firefox, Safari — rather than one.
- **It runs on macOS 13.** The closest rival by provider coverage needs macOS 15.

Four gaps closed in this release, which is worth saying because the ones still open are listed right after: Codex was the single biggest hole and has a row of its own now, Claude Code's local stats are read off this Mac with no network at all, there is a history view with a chart and a per-day table, and spend has budgets and their own alerts.

Where the others are ahead, plainly:

- **openusage** ships as a signed, notarised universal DMG with in-app Sparkle updates and a Homebrew cask. aibars builds from source on your machine and has no update mechanism at all. It also has three things aibars does not: a one-shot CLI, a loopback HTTP API other tools can read, and a global keyboard shortcut for its popover. It documents ten providers and needs macOS 15.
- **AIQuotaBar** ships a WidgetKit desktop widget and a 90-day heatmap window. aibars has no widget — that needs a second target, and the menu bar is the point — and its history is a line chart with a table rather than a heatmap.
- **ClaudeMeter** offers six menu bar icon styles for Claude alone and is the most polished single-service option in the category. aibars draws one strip and spends its configuration on the panel instead.
- **Antigravity, Devin and Pi** are covered elsewhere and not here. The first two are Codeium-lineage Connect RPC endpoints nobody has verified against a live account in this codebase, and shipping unverified network providers is how you end up with providers that report plausible-looking wrong numbers.
- **Codex reset credits.** OpenAI exposes a route that spends one of an account's rate-limit reset credits to clear its windows early, and aibars deliberately does not call it. Reading an account and spending from it are different things, and a menu bar item should not be one mis-click from an irreversible purchase.

And what none of us can fix: ChatGPT and Copilot do not expose numeric quota to any endpoint a browser session can reach, so nobody's percentage for those two is real. aibars shows a status line for them rather than a number.

## Connecting a service

Usually you don't. If you're already logged into a service in your browser, aibars adopts that session during the launch sweep and the row is connected before you touch anything. Claude Code and OpenCode need even less: if the tool has run on this Mac, the row has data.

When it can't, click **Sign in** on the row in the panel, or **Connect…** in Settings → Services. Both open the same window, and it handles every case, and it says which case you are in: a session found in three profiles and asking which account this is, a session found but locked behind the Keychain, a credential the service rejected, an account whose session quietly expired, a token you have to generate and paste. Login pages open in your own browser on the provider's own page; nothing is rendered inside aibars, because your password and your 2FA already live over there.

Copilot, DeepSeek, OpenRouter and Z.ai are the exceptions to hands-off capture: their APIs want a personal access token or an API key rather than a session cookie, so aibars opens the right page and takes what it gives you. Codex sits in between — it uses the ChatGPT session if that works, and otherwise the login the `codex` CLI has already left on the machine.

Claude Code and OpenCode have no Connect button, because there is nothing to give: the files are there or they are not. Their rows in Settings → Services say what they are reading and offer Reveal in Finder instead, and signing out of one means "stop reading it" rather than deleting a history aibars did not create.

Signing out clears aibars' copy of the credential and nothing else. Your browser session is left alone — clearing it would log you out of the website itself. What is dropped alongside it is that account's samples, its armed alert levels and its stored history, because slot numbers are reused: the next session discovered for that service takes the same id, and months of somebody else's usage under a new account's name is not a stale number, it is a fabricated one.

### Which browsers this works with

| Browser | Works | Notes |
|---------|-------|-------|
| Chrome, Edge, Brave, Arc, Chromium, Opera | Yes | Cookies are encrypted with a key in your login keychain. aibars asks for that key per browser, and only when you press Unlock in Settings → Services or in the connect window — a background sweep never raises the dialog. Decline and you can still paste a token. |
| Firefox | Yes | Cookies are stored in plaintext; nothing to unlock. |
| Safari | Needs Full Disk Access | Safari's cookies live in a TCC-protected container. The connect window offers a shortcut to the setting. |

Every connect window also takes a pasted token, so no browser is a hard requirement — and the two local sources need none at all.

aibars ships unsandboxed. Reading Chromium's profile cookie databases, Safari's `~/Library/Cookies/Cookies.binarycookies`, the login keychain's Safe Storage items and two command line tools' own data directories is not something the App Sandbox permits, so the entitlements file turns it off. The only other entitlement is the network client.

aibars sends its requests as itself. Browser-impersonating user agents were added at one point and taken back out again: nobody asked for them, they contradict what this page says about being a good citizen, and the honest failure — a row reporting that the site's bot protection refused it — is already modelled, and is deliberately not treated as a dead session, so a hotel wifi splash page does not cost you a working cookie.

### What is stored, and where

Sessions read from a browser are held in memory only and re-derived at the next launch, which takes about half a second. They are deliberately never written to the Keychain: a locally signed build gets a new signature on every rebuild, so the old access control no longer matches and macOS would ask you to approve the item again every time. Having nothing to ask about is cheaper than answering.

Pasted API keys can't be re-derived from anything, so those do go in the Keychain — one item, `aibars.tokens`, read at most once per launch.

The usage history is the SQLite file described above, in `~/Library/Application Support/aibars`.

Everything else is UserDefaults: which services are enabled, your appearance settings, the alert rules and their armed state, your budgets, the six-hour sample rings behind the forecast, and the watermarks that let Claude Code's index re-read only what has been appended since last time.

The local sources are read, never written. Claude Code's transcripts and OpenCode's database belong to those tools; aibars reads them where they are, copies OpenCode's database to a temporary file before querying it so it never contends with a live one, and deletes nothing.

No usage data leaves your Mac, there is no server, no telemetry and no analytics.

## Settings

- **Services** — connect, sign out, name an account, show or hide a service, a per-browser list of the sessions aibars can see with an Unlock button for the locked ones, and the two local sources with where each one reads from
- **Appearance** — five presets (Comfortable, Compact, Minimal, Dashboard, Monochrome) over sections for Size, What each row shows, Usage meter, The list and Menu bar, with a live preview and a Reset that puts everything back to how it shipped
- **History** — the chart, its range, the per-day table, and the three things you can do to an archive: stop adding to it, take a copy, throw it away
- **Spend** — what each service says it cost, a cap per service and one overall, and the two warning levels
- **Alerts** — the alert switch, both thresholds, the reset announcement, the pace line, macOS's permission state and the last five alerts with whether they were delivered
- **General** — launch at login, and the refresh interval: 30 seconds, 1, 5, 15 or 30 minutes
- **About** — version and links

The menu bar strip is configured under Appearance → Menu bar: how many services it carries (one to three), its height (10–16pt), and whether it spends colour — monochrome, which keeps it a template image so the bar gives it its own light, dark and vibrancy treatment; colour only above the warning threshold; or colour on every figure.

Both previews in that pane are the real thing. The strip preview builds the same view the status item rasterises, through the same width fit, so it drops a segment exactly where the bar would. The panel preview is measured by the same `RowGeometry` a panel row is and draws the same riser and the same cut. A preview that disagrees with the thing it previews is worse than no preview, so there is one copy of that arithmetic and both call it.

## Project layout

```
aibars/
├── install.sh                  builds from source and installs the app
├── project.yml                 XcodeGen config (3 targets: aibarsCore, aibars, aibarsTests)
├── Sources/                    aibarsCore framework
│   ├── Models/                 UsageData, SpendReport, UsageProvider protocol
│   ├── Auth/                   Keychain, cookie extractors, HTTP client, web login
│   ├── Brand/                  SVG path parser + provider logos
│   ├── Providers/              one file per service — see the table above
│   ├── Local/                  Claude Code's log scanner, its index, and the rate card
│   ├── Forecast/               burn rate and time-to-cap, and the sample ring behind it
│   ├── History/                the SQLite store and the queries the chart reads
│   ├── Spend/                  budgets, and what a budget means
│   ├── Notifications/          threshold and budget policies (pure) and their delivery
│   ├── System/                 launch at login
│   ├── Views/                  design tokens, SwiftUI views, connect window, settings window
│   └── AppState.swift          AppState (service registry, polling) + AnyUsageProvider
├── SourcesApp/                 aibars app target (thin wrapper)
│   ├── aibarsApp.swift         @main + MenuBarExtra scene + the status item's strip
│   └── aibars.entitlements     Network client; sandbox off (reads browser cookie stores)
└── Tests/                      XCTest for parsers, policy, forecast, geometry and layout
```

The split exists so the app can ship with `@main` while unit tests run against the framework without bootstrapping the UI. The decisions worth testing are kept out of the views, and that now covers most of the visual system too: `UsageForecast`, `ThresholdPolicy`, `BudgetPolicy`, `HistoryQuery`, `RowGeometry`, `PaceGeometry`, `MeterCut`, `RowSpine`, `StripFit` and `MenuBarStripContent` are pure functions over their inputs, with no app state, no I/O and no notification centre in them. A row's height, a rail's width, whether a bar is cut, why a row spines and which segment the strip drops are all things a test can assert rather than a person eyeball.

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
                // instead of a bar, is left out of the history, and is never
                // forecast or alerted on.
                limit: ProviderNumber.coerce(raw["limit"]) ?? 0,
                unit: "reqs",
                // Both of the next two, or neither. The reset alone earns a
                // countdown; the reset and the window's own length together
                // earn the riser on the bar, and a guessed length would be a
                // guess drawn as an instrument.
                resetDate: ProviderDate.parse(raw["resets_at"] as? String ?? ""),
                windowDuration: 5 * 3600
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

2. Register it at the **end** of `AppState.services`: `Service(id: "myprovider") { AnyUsageProvider(MyProvider(accountID: $0)) }`. Declared order is the sort tiebreak and the fallback for a custom order, so slotting one in above an existing service reshuffles rows that have been sitting still for people who already use the app. Nothing else is needed to make token entry, multi-account discovery, forecasting, history, budgets or alerts work — `AnyUsageProvider` dispatches through the protocol rather than switching on the id, and the sampling, the history store and the threshold policy all key off `id` and the metrics you return.
3. Give it a logo — either add a `BrandMark` entry in `Sources/Brand/BrandMarks.swift` (single-path SVG data plus its view box, 24×24 for simple-icons glyphs) or drop an image named `logo-myprovider` into an asset catalog. Without either, the row falls back to a lettermark in `accentColor`. The strip keys its mark off `serviceID`, so a service with no glyph is a single letter at 13pt.
4. Add a test in `Tests/aibarsTests/`, against a real captured response with the identifying parts removed. There is a file per provider's parser.

If money is involved, return it as a `SpendReport` on `UsageData.spend` rather than as a metric, and set `confidence` honestly: `.measured` is the provider's own ledger, `.estimated` is arithmetic done here. That field is the only thing standing between a bill and a guess.

## Contributing

PRs welcome. Keep changes focused — one provider or one fix per PR. Run `make test` before submitting; the build is warning-free and should stay that way. See `CONTRIBUTING.md`.

Please don't commit any real session tokens or other secrets. `SECURITY.md` has the disclosure address.

## License

MIT — see `LICENSE`.

## Credits

Provider logos are single-path glyphs rendered at runtime by the small SVG path parser in `Sources/Brand/SVGPath.swift`. Most come from [simple-icons](https://github.com/simple-icons/simple-icons) and are used under [CC0-1.0](https://github.com/simple-icons/simple-icons/blob/develop/LICENSE.md), the Z.ai, Claude Code and OpenCode marks included. Two exceptions. The OpenAI mark — drawn for both the ChatGPT and the Codex row, because there is no separately published Codex glyph and inventing one would mean drawing somebody's trademark for them — is the glyph simple-icons published under CC0 up to v14, which was removed from that set in November 2025 pending brand permission. And the Grok mark comes from xAI's own brand assets and is not CC0: it is reproduced only to identify the service, in its own shape, recoloured where a near-black mark would otherwise be invisible on a dark background. The logos remain trademarks of their respective owners and are used only to identify the service each row reports on. aibars is unofficial and is not affiliated with, endorsed by, or sponsored by any of these companies.

## Disclaimer

This is an unofficial project. Most of the usage endpoints aibars reads — Claude, ChatGPT, Codex, Gemini, Grok, Perplexity, Cursor, Copilot, Mistral and Z.ai — are not documented public APIs and may change or disappear without notice. Only DeepSeek's and OpenRouter's are documented. Claude Code's transcripts and OpenCode's database are undocumented file formats belonging to those tools, and both are checked before they are read, so a schema change reads as "aibars cannot read this yet" rather than as usage that silently went to zero. The generic provider reads whatever endpoint you point it at. aibars reads only what your own browser session or your own files already have access to, with your own credentials, on the interval you set. Be a good citizen — don't hammer the endpoints.

## Roadmap

- ~~One-click auth (no more copy-paste)~~ — done, by handing off to your own browser rather than hosting a WebView
- ~~Chrome cookie decryption~~ — done
- ~~Burn rate and a predicted time-to-cap~~ — done
- ~~Warn before a cap is hit~~ — done
- ~~Launch at login~~ — done
- ~~A history view~~ — done: 14 days of readings, 400 days of daily summaries, a chart and a table
- ~~Per-window cost estimates in USD for the services that report money~~ — done, with budgets and their own alerts
- Antigravity, Devin and Pi, once their endpoints have been verified against a live account
- A signed, notarised build and some way to update one, which is the largest single gap against the closest rival. Building from source is the only route today
- Saying in words that an account at 100% with extra usage switched on is not actually blocked. The overage spend is already read and shown; the sentence beside a full meter is not there yet
- Swift Charts for the history view, if and only if the floor ever moves to macOS 14 — every interactive API worth adopting it for arrived there, and the hand-drawn chart is at least visible to VoiceOver
- Not planned: a WidgetKit widget. It needs a separate target, and the menu bar is the point
- Not planned: spending a Codex reset credit from the menu bar. Reading an account is not the same as buying from it
