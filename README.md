# aibars

A native macOS menu bar app that reads your usage out of fifteen AI services — Claude, Claude Code, ChatGPT, Codex, Gemini, Grok, Perplexity, DeepSeek, Cursor, GitHub Copilot, OpenRouter, Mistral, Z.ai, OpenCode, and a generic JSON one — using the sessions already open in your browser, or, for the two local sources, the files those tools already write on your Mac. Swift and SwiftUI, no dependencies, macOS 13+, MIT.

Several apps do this. [How aibars compares](#how-this-compares) is further down, including the parts where the others are ahead.

```
   ✦ 97   ✳ 92   ◆ 64     the menu bar: a brand mark and its own figure per service
╭────────────────────────────────────────────────────────╮
│ ▇▅▃▁ aibars  updated 12s ago               ↻  ⌁  ⚙  ⏻  │
├────────────────────────────────────────────────────────┤
│ ✦  Gemini  Pro                                    97%  │
│    ████████████████████████▏█░                         │
│    Daily · on pace to cap in 5m      resets in 2h 59m  │
│                                                        │
│ ✳  Claude  work · Max 20×                         92%  │
│    ████████████████████████░▏░                         │
│    5h session · resets in 1h 19m       Weekly 61%  +1  │
│                                                        │
│ ◆  Cursor  andrew@… · Pro                         64%  │
│    █████████████████░░░░░░░▏░                          │
│    320 / 500 · on pace to cap in 1h  resets in 8d 15h  │
│                                                        │
│ ◍  ChatGPT  Plus                                    ●  │
│    Subscription active                                 │
│                                                        │
│ ⌀  Grok                                             ⚠  │
│    No response — will retry                            │
│                                                        │
│ ›  Not connected  7                                    │
╰────────────────────────────────────────────────────────╯
```

The `▏` in each bar is the redline, and it is the one mark in there that has to be explained: a one-point notch of the panel's own ground, standing at your warning threshold and cut through the fill rather than drawn under it. Gemini's fill has run past it, Claude's has not, and Cursor's is nowhere near. [The meter](#the-meter) is the rest of it.

Two other things in that picture are decisions rather than accidents. The pace claim — `on pace to cap in 5m` — is a run at the tail of the caption and not a line of its own, so it can arrive and leave without moving anything; on the Claude row it has been dropped, because that line is already carrying a further window and a count of the one that would not fit, and the pace is the first thing to give. Widen the panel and it comes back. And the countdown sits on the trailing edge wherever nothing else does, so "when does this come back" reads down the panel at one x.

Everything in that panel is configurable, including how much of it is drawn: five presets and the thirty-two settings behind them sit under Appearance, with a live preview of a real row.

One rule sits under all of it: **a row's height is a function of your settings and of one bit — has this row anything to report at all — and of nothing else.** Never of what came back from the fetch, never of a string that had to be measured. `MenuBarExtra` sizes its window to its content, so anything content-dependent is the panel resizing under your pointer. Everything that could grow a row is therefore reserved from the setting that switches it on and held whether or not there is anything to put in it — the sparkline's box, the ladder of further windows, the budget line, the meter's own slot on a row that reports no quota, and the box the hover buttons live in. Empty rungs are the price. They are drawn as rungs rather than left blank — an unfilled line of the further-windows ladder carries the panel's own hairline where a window's label would start — because reserved space that looks like nothing reads as a render that failed.

The bit is deliberately "has anything to report" rather than "is signed in", and the difference is a state you will actually meet: a session that expires while the panel is open. That row still has its last reading and the sentence explaining what happened, so it keeps every box it had — including the buttons' box, which it no longer draws buttons in. It gives their *width* back to its own name, because that is space the name wants and nothing is measured by. A row nobody has connected is the one short row, and it is short from the moment the panel opens.

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

There is no Dock icon and no main window. After launch the only sign of aibars is a strip in your menu bar: by default one brand mark and its own figure per service, closest to its cap first, so you can tell which number is Claude's and which is Cursor's. Click it for the panel above.

Six drawings are available under Appearance → Menu bar, chosen from a grid of chips that each carry the real strip rather than a picture of one:

| Style | What it draws | Services |
|-------|---------------|----------|
| Mark + figure | A brand mark and its own reading per service. 130pt at three. | up to 3 |
| Figures only | One number, no mark. | 1 |
| Marks only | Silhouettes, tinted by how close each is to its cap. Nothing is tinted under Monochrome. | up to 3 |
| Micro bars | One column per service on a shared baseline. The only style that still measures under Monochrome, and the only one that does not say which column is which. | up to 3 |
| Mark + meter | A mark and a small column beside it — identity and a magnitude in 21pt a service. | up to 3 |
| Closest to its cap | One service, whichever is nearest its cap, spelled out with its reading. | 1 |

Two of them speak for exactly one service, and where they are chosen the services stepper is greyed out rather than left to move a number nothing reads. The count you had set is kept, so trying one and going back restores it.

The strip is disciplined about width, because it shares a 22pt bar with everyone else's status items:

- **Up to three services**, your choice of one, two or three under Appearance → Menu bar, for the four styles that can carry more than one.
- **A reserved cell per figure**, three characters wide, sized once from the widest reading the strip can produce and never measured from the string in hand. A service crossing 99 into 100 does not widen the item and does not shove the icons to its left sideways.
- **A total cap of 148pt of drawing.** Over that, the least urgent segment is dropped until the item fits, because an item that keeps growing starts pushing other people's status items off a notched laptop.
- **A dash for a service that reports no quota.** ChatGPT reports a subscription and Copilot reports a seat; neither is a percentage, and an invented 0 reads as plenty left while an invented 100 reads as capped.

Two accounts of one service collapse to one segment in the strip — the busier of the two — because the same mark twice with two numbers reads as a rendering fault. The panel underneath is where accounts are told apart.

Refresh, history, settings and quit are the four buttons in the panel's header; ⌘R refreshes, ⌘, opens Settings, ⌘Q quits. The history button goes straight to the chart rather than to whichever pane Settings was last left on. The panel can also be opened by a shortcut and driven without the mouse at all — see [the keyboard](#the-keyboard).

If you can't find the strip, the menu bar is probably full: macOS hides items it has no room for. Widen it by quitting something else in the bar, or move aibars leftwards by ⌘-dragging it.

## The keyboard

### A shortcut to open it

Settings → General → Keyboard. Nothing is bound until you record one: a menu bar app that takes a system-wide key combination before anyone asked is the same imposition as priming notifications at launch, which this app also refuses to do.

It goes over Carbon's `RegisterEventHotKey`, and that is the whole reason it is shippable. `NSEvent.addGlobalMonitorForEvents` and `CGEvent.tapCreate` both need Accessibility permission — a TCC prompt and a trip to System Settings, for a keyboard shortcut — and neither takes the keystroke away from the app in front, so your combination would also type into whatever was frontmost. Carbon needs no permission and no entitlement, and the WindowServer withholds the combination from everyone else while aibars holds it.

The honest limit: nothing on macOS can answer "who owns this combination". `RegisterEventHotKey` returns success even when another app already has it. So the recorder refuses the slice that can be refused — the shortcuts macOS itself holds, read live out of `com.apple.symbolichotkeys` — and for the rest the footer says in words that a combination another app took first will simply do nothing. There is deliberately no "test this shortcut" button, because it could only ever report silence, which is what pressing the key already told you.

### Type to filter

Start typing with the panel open. The first printable character turns the header's summary into a filter line — no text field, no fifth button, no bezel and no focus ring — and the list narrows as you go. The count on the right is how many rows matched.

A query matches a row's name, its initials (`cc` finds Claude Code, `gc` GitHub Copilot), a short list of aliases per service, the account label and the plan — every one of them a string the row actually prints, so the filter never matches on something invisible. Ranking is banded, first hit wins: an exact name, then a prefix, then an alias, then initials, then a substring, then the account, then the plan, and last a subsequence, which is what finds Claude Code from `clcd`. Not a sum of bonuses, because a number arrived at by adding four of them cannot be explained to the person looking at the list. Ties keep whatever order the panel was already in, so two equally good matches cannot swap places between keystrokes.

Initials need two characters and a subsequence needs three. Below that they hit nearly every row, so the list would reorder without narrowing — which is the worst thing a filter can do, because the row your eye had already found moves.

Two rules it holds:

- **A filter never resurrects a row your settings hid.** If the best match is a service you switched off or a quotaless row you hid, the panel names it and says which pane it went to, rather than returning nothing and reading as broken.
- **The panel does not resize while you type.** `MenuBarExtra` sizes its window to its content, so a list that re-measured on every keystroke would be worse than no filter at all. The list box is latched at its resting height the moment filtering opens and held until it closes: a panel filtered to one match measures exactly the same as the same panel filtered to three.

### The keys

| Key | What it does |
|-----|--------------|
| any character | begins filtering |
| ⌘F | begins filtering with nothing typed |
| ↑ ↓ | moves the selection; it clamps at both ends rather than wrapping |
| Home, End | first row, last row |
| ⌘1–⌘9 | selects the nth row on screen — selects, never activates |
| Return | opens the selected row's dashboard, or starts its sign-in |
| Esc | clears the filter and the selection; again to close the panel |
| ⌘R / ⌘, / ⌘Q | refresh, Settings, quit |

Everything carrying ⌘ is passed straight through to macOS except ⌘1–⌘9 and ⌘F. That is not tidiness: key equivalents are dispatched after every local event monitor, so a panel that swallowed ⌘Q would leave an app with no Dock icon and no window unquittable except by Force Quit. There is a test whose only job is to assert that it doesn't.

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

Rows that report a state rather than a quota — ChatGPT, Copilot, and every figure Claude Code reports — draw a status line instead of a bar, are never counted towards the menu bar strip, are not recorded in the history, and are never forecast or alerted on. A service with no ceiling has nothing to run out of: "reports no quota" and "is at 0%" are different statements and the panel has to be able to make both. The meter's slot is still held open on those rows, and it draws nothing at all — an empty track would say 0% and a rule would read as a table divider, so the row says it in words and spends the space on the seam below instead.

The two local sources are honest about what they are. Claude Code's transcripts are the only place on the machine that says what the local agent has spent — the web endpoints know nothing about it — so those numbers are complete for this Mac and say nothing about another one. OpenCode is the same shape with a sharper edge: its caps are the published plan limits, which are facts about the product, but the numerator is only what this machine recorded, so a Go account also used from a second Mac reads low here. The row says "this Mac" for exactly that reason.

## The meter

A progress bar fills towards something you want. A quota meter empties towards a cliff, so the informative half of the reading is the part that is *left* — and a plain bar gives that half the least ink. At 92% you get a long bright bar and a sliver of track, which pre-attentively reads "plenty", which is the opposite of what it says.

Two things answer that:

- **The redline.** A one-point notch stands at your warning threshold, drawn in the panel's own ground and drawn *over* the fill rather than under it, so it survives being overtaken. Below the threshold it stands in the empty track; at it the fill's edge meets it; above it the fill visibly runs past. It is a position channel, which is why it is worth having: a tick the fill either has or has not reached survives greyscale exactly, survives deuteranopia exactly, survives Monochrome exactly, and is legible on a 5pt bar.
- **The bar is bounded at both ends.** It used to be 304pt of a 356pt panel — 85% of the window, aspect 61:1 — and 468pt at the top of the width slider. At that length it read as a rule between a title and its own caption, it carried over 90% of all the colour in the panel, and it resolved a third of a percent per point against a figure that is only ever printed to the nearest whole one. The track is now half the text column, floored at 160pt and capped at 200: 160 at every panel from 300pt up to and past the shipped 356, 184 at 420, 200 at 520. It is leading-aligned, so every bar in the panel starts on the same edge, and the ceiling is where the bar's resolution stops being within a factor of two of the figure two columns away — past 200pt the bar visibly moves while the number holds still.

A row at or above the warning threshold says so four times over, and only one of the four is colour:

- **position** — the fill has run past the redline,
- **shape** — the fill's trailing end squares off,
- **weight** — the figure goes from medium to semibold,
- **colour** — last, and never load-bearing on its own.

Convert the panel to greyscale and the row is still identifiable. Set the ramp to Monochrome and it still is.

Two drawings that used to be here are gone, and it is worth saying which. The bar carried the reset clock in its track and a riser at the pace boundary, so it drew two quantities where everything else in the category draws one. It was a real idea and nobody could read it: an instrument nobody arrives already knowing has to be documented before it can be used, and a menu bar panel is not a thing people read documentation for. The pace still has its say, in words, at the tail of the row's own caption. The other was the spine — a coloured bookmark down a row's leading edge, meaning near-cap *or* needs-you *or* failed-outright, with no way to tell which from looking at it. A row that wants you now says `Sign in`, in words, in its own figure rail.

## Colour

There are exactly two hues in the whole application. Amber and red, and both mean alarm.

The two of them rank, and it took a re-cut to make them. In dark, 97% had been drawing in a salmon at OKLCh chroma 0.107 while 92% drew in an amber at 0.151 — the *less* urgent reading was the more saturated one, so the eye went to the second-worst row. The rule now is that chroma never decreases going up the ramp: resting 0.011 → amber 0.113 → red 0.160 in light, 0.012 → 0.141 → 0.160 in dark. Red is also the darker of the two in both appearances, by about ten points of L\*, so which alarm it is survives a greyscale screenshot. The cost is stated rather than hidden: in dark that makes the red bar the *darker* of the two, which is the opposite of what a lightness ramp would do. Nothing rests on it — near-cap is carried by three channels that are not colour at all — and there is a test that desaturates a rendered panel rather than trusting this paragraph.

Everything else is a grey. The grounds are near-black (`#0C0D11`) and near-white (`#F6F7FA`); text, marks and captions come off one ink ladder; the meter's resting fill, its track, and the heatmap's five steps are all points on the same greyscale. The app used to run three colour systems at once in 356 points — fifteen brand marks at full saturation, a usage ramp with its own amber and red, and a semantic green/amber/red beside them — and the raw brand hexes out-chromaed every colour that meant something, so an alert could not announce itself over the row's own logo. There is no green: a connected service that is not answering was never green, and the one dot that used to be green is now the body ink, because the dot's job is proof of connection rather than approval.

The one exception is identity, and it is bounded. **A brand mark carries its own hue when its row is connected and reporting, and a grey when it is not** — the same muted grey the row's own name and caption take in that state, so colour on a row means the same thing colour means everywhere else in the panel: this one is live. Even then it is only hue. The live band holds the mark grey's exact lightness and caps chroma below the alarm amber's, so a logo can never out-shout a warning, and turning the hue off moves no contrast ratio anywhere in the app. Seven of the fifteen brands have no hue to carry — OpenAI's two, Cursor, Copilot, Grok, Z.ai, OpenCode — and they fall through to the mark grey, which is that same rule evaluated at zero chroma rather than an exception to it.

Two things suppress it. The Monochrome preset, which is what that preset is for. And the Provider colour ramp, where the meter and the figure are already painted in the brand's hue — a row whose mark, bar and number are three shades of one colour is exactly what "chroma means measurement" exists to prevent, so brand hue appears at most once per row and the meter wins. There is no switch of its own for it, which is a gap: today the only way to have grey marks is to take the whole Monochrome preset.

The rest is deliberately quiet. One material in the whole app, one typeface, and every number set with tabular figures inside a reserved, right-aligned column — so nothing on screen shifts as the digits tick, including on rows with no figure, rows still loading and rows that will never report one. Under Increase Contrast the hairline rules and borders step up in opacity — 0.07 to 0.16 for a rule, 0.18 for a border; no line anywhere gets thicker. Under Reduce Transparency the material is dropped rather than covered, and the ground goes fully opaque.

**One typeface** is a change from what shipped first. Figures used to be SF Mono while every word beside them was SF Pro, on the theory that a monospaced face is what makes a column. It isn't: the columns are the reserved rails and the fixed digit advance, and `.monospacedDigit()` gives both of those on the system face. What SF Mono added on top was its voice — slab terminals, an exaggerated aperture, a slashed zero — and eleven rows of it down a panel read as a terminal window rather than as an instrument. Every figure in the app sits a few points from a word, and two faces on one line is a seam the eye finds before it finds the reading. So `92%` and the name beside it are now the same face at different weights, which is what hierarchy is supposed to be made of.

That cost something worth naming, because it is the part that is not just taste. A mono face has one advance at every size and every weight, so a rail could be cut from a single constant: `size × 0.6185`. SF Pro has neither property — its tabular digit runs 0.648 of the point size at 9pt and 0.610 at 16pt as the optical size changes, and another 3.5% wider again at semibold — and its `%` is 1.47 times a digit where SF Mono's was exactly one. So every rail in the app is now measured off the real face at the weight its run is actually drawn in, and the unit letters have a cell of their own. The reservations moved by a few points each; the invariant they exist for did not move at all.

The one thing the chrome never does is take an alarm colour. The rule under the header stays neutral whatever the rows are doing, because a coloured edge across the top of the panel names no service and cannot be acted on.

One place light mode is honestly weaker than dark: its amber. `#894800` is a burnt orange rather than the gold dark gets, and it sits there because the same token is a *figure* as well as a bar — a percentage set in amber on a pressed card over a white wallpaper has to clear 4.5:1, which caps it at L\* 38.3, and there is no amber at that lightness. The alternative is a second amber for the fill alone, and two ambers is exactly the drift that produced `#B45309` and `Ink.attention` as separate colours once already. So the ranking is right in both appearances and the light ramp is duller; that is the trade, not an oversight.

## The mark, and the icon

The app mark is four bars descending onto an axis, and it is cut on a whole-point grid: `AppMarkGeometry` answers every measurement as integer arithmetic with no view in it, so at 12, 14 and 22 points there is not one partially lit pixel above the axis at 1× or 2×. It is hinted rather than scaled — the menu bar and the panel header draw the same stems at the same pitch and differ only in bar heights, which matters because the panel hangs directly under the status item and the two are on screen together.

The application icon is the same mark and the same grid, in near-white on a graphite tile, on the 824-of-1024 square the system cuts its own icons on. What it does not take is the hinting: whole-point rounding exists for a 13pt glyph, and at 374pt it would quantise the drawing for nothing. It is authored in code (`AppIconArt`) and cut to ten PNGs by a gated harness, so the icon cannot drift from the mark and nobody has to open a drawing tool to change it.

## The last day, on the row

Off by default; Appearance → What each row shows → 24-hour sparkline turns it on for every connected row at once.

Twenty-four hourly buckets of that row's headline window, one point an hour at the highest reading in it, in a fixed box under the meter. One neutral trace, and deliberately no usage colour: the meter beside it is the reading, and this is context. So a row reads the last day in the trace, this instant in the bar and the figure, and the next hour in the pace claim on the caption line.

- **Gaps are cut, not bridged.** An hour nothing landed in is absent rather than zero, and the trace stops and restarts across it. A Mac that was asleep did not spend a quiet night at the floor, and joining across the gap would draw exactly that night.
- **A window rolling over cuts it too**, at the same thirty-point drop the history chart splits its own line on, so the panel and the settings window agree about where a window began. Joined, a reset is a vertical plunge through the whole box, which reads as the app having lost the data rather than as a subscription renewing.
- **The slot is reserved from the setting, never from whether there is anything in it.** Switch it on and every connected row grows by the same amount immediately, including the ones with no history yet — which is why the first day is an empty box rather than nothing. A row that grew when its own history arrived would resize the panel under the pointer a day after you connected the service.

It reads a cache in front of the database rather than the database, rebuilt at most once every five minutes per row, so drawing eleven rows is eleven dictionary lookups instead of eleven synchronous SQLite queries on the thread doing the drawing.

## Pace

At the tail of a row's caption line, when there is something honest to say:

```
5h session · resets in 1h 19m · on pace to cap in 40m
5h session · resets in 25m · you'll finish under
```

It is a run on a line the row already draws, not a line of its own, and that is a height decision before it is a typographic one. It was a block under the meter for one release, and the first projection to qualify grew its row 19pt — about 171pt down a full panel — with the panel open. Reserving the block instead would have been worse: a fit needs three samples five minutes apart, a rising slope and an arrival inside twelve hours, so a freshly launched panel has a projection for nothing at all and would have paid the whole 171pt anyway. On the caption it costs nothing and can never cost anything, because that line is one line box whatever is on it.

Two consequences follow, and both are wanted. It is the **first** thing the line drops when it runs out of width — offered as the richest of five candidates, so a caption too tight to carry the claim draws exactly what it drew before the pace existed, never less; a countdown is a fact the provider published and the pace is a claim fitted from half an hour of samples, so where they compete the fact wins. And it follows the line rather than the row: under Minimal, which reserves no caption at all, there is no line to ride and no claim is made, which is that preset's whole premise.

It is set one size down from the rest of the line, because everything else there is something the provider said and this is something aibars worked out. It takes no colour at all — a warning ink on a sentence over a bar resting in grey would report a state the row is not in.

The answer is always stated against the window's own reset, never as a bare clock time. "2:58 PM" with no date is the thing people complain about most in this category of app, and it is also the least useful form of the answer: what you want to know is whether the cap arrives before the window rolls over.

The second sentence is the one that has to be careful about it. It is reached only when the window renews before the cap arrives *and* the renewal is inside twelve hours, and its full form — "resets in 25m, you'll finish under" — names a reset the countdown two runs to its left has already named. So it gives up that half when the countdown is on and keeps the half only it can say. Which half goes is decided from the setting and the presence of a reset date, not from what the caption finally fits: the candidate ladder can drop the countdown to make room, and a claim whose wording changed when you dragged the panel wider would be worse than the repetition.

How it works: aibars keeps the last six hours of readings per account, fits a recency-weighted line through the last half hour of them (ten-minute half-life, so a burst that has just started still moves the estimate), and divides what is left of the cap by that slope. A drop of twenty points or more is treated as the window resetting, and everything before it is discarded, so a fresh 5-hour window is never projected off the last one's slope.

It refuses to answer more often than it answers, on purpose. Nothing is shown when there are fewer than three readings, when they span less than five minutes, when the newest is more than fifteen minutes old (the Mac slept, or you stopped working), when usage is flat or falling, or when the projected date is more than twelve hours out. A line drawn through one reading is not a forecast.

And it is an extrapolation, not a promise. It assumes you carry on at the rate of the last half hour. Stop for lunch and it goes quiet rather than counting down; open six tabs and it will be late.

The same projection, in a shorter form, also goes in the panel header — "caps in 40m" beside the busiest service. The claim on the rows can be switched off in Settings → Alerts → Pace.

## History

Settings → History, or the chart button in the panel's header.

One usage window at a time — every account listed separately, since two logins to one service are spent at their own rates — over 24 hours, 7 days, 30 days or 90, drawn as a line on a 0–100% axis with the warning threshold marked. Hovering reads out the bucket under the pointer. Under the chart, one row per day: the day's peak, the mean of its readings, how many times the window crossed its cap, and how many readings the first two rest on, because a mean over two samples and a mean over two hundred are not the same claim.

### The ninety-day grid

Between the chart and the table, ninety squares, one a day, at that day's peak. It joins the chart rather than replacing it: the chart answers what shape the selected window had, the grid answers which days. It ignores the range picker for the same reason — a seven-day heatmap is seven squares, which is a worse table than the one underneath it.

Three things it deliberately does not do:

- **It does not use a hue ramp.** The scale is one neutral getting darker in light and lighter in dark, and the only cells that take a colour are the ones at or over your own warning line. That is what keeps the coloured cells countable on a grid of ninety, and it is why the four filled steps are even quarters of the range *below* your threshold — move the threshold in Appearance and the whole ramp and its legend move with it.
- **It does not draw a cap hit as a sixth colour.** A day the window crossed loses its corners instead, which is the one channel that survives greyscale, Monochrome and a reader who cannot separate the amber from the red.
- **It does not resize.** The box is the same size whatever landed in it — no days, three days, ninety — so the first pass draws an empty grid and the answer arrives into the same frame. A three-day install gets all ninety squares and a line under them saying how many are real, because eighty-seven empty ones otherwise read as three months of doing nothing.

The columns are pushed right so today's week is always the last one. Ninety days spans thirteen calendar weeks on two weekdays out of seven and fourteen on the other five, and left as it falls the blank week sits where today is, so the grid would appear to stop several days ago every Monday. Fourteen columns are drawn always, for the same reason: a grid that narrowed by a column twice a week is the settings window's version of the panel resizing under the pointer.

It is one focus target and not ninety. Ninety tab stops between a picker and a toggle is hostile, so the grid takes focus as a whole and the arrows walk a pinned day by ±1 and ±7 through the cells themselves rather than through the calendar — which is what keeps them right across the spring-forward Sunday. Every cell still carries its own tooltip.

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

- **It reads each provider's own usage endpoint** using the session already sitting in your browser. There is no cookie to paste and no table of plan constants in the source to go stale — which is the failure mode that made every log-scraping tool in this niche start lying quietly the week a provider changed a limit. When a provider changes what it reports, the row changes with it.
- **Fifteen services and several accounts per service**, discovered rather than configured. Two Claude logins in two browser profiles come up as two rows.
- **It answers the forward-looking question.** Most of these apps tell you where you are now. The pace claim tells you whether the cap arrives before the window resets, stated as a duration against that reset, and says nothing at all when the samples can't support a claim.
- **The meter is a gauge rather than a progress bar.** A redline stands at your own warning threshold and the fill either has or has not run past it, so the empty half of the bar — the half that actually matters on a quota — is the half you read.
- **The panel does not resize while you are looking at it.** Every row's height comes from your settings and nothing else — not from what the fetch returned, not from a string that had to be measured. That is a strange thing to advertise until you have used a menu bar panel that jumps under the pointer as its answers land.
- **Near-cap is said four ways and only one of them is colour.** Position, shape, weight, then hue. A greyscale screenshot of the panel is still readable, and so is the panel with the ramp set to Monochrome.
- **It reads any browser you actually use** — Chromium and its forks, Firefox, Safari — rather than one.
- **It runs on macOS 13.** The closest rival by provider coverage needs macOS 15.

Gaps closed since the last release, which is worth saying because the ones still open are listed right after: there is a global shortcut for the panel, a 90-day heatmap in the history pane, six menu bar strip styles rather than one, a per-row sparkline, and type-to-filter with full keyboard navigation.

Where the others are ahead, plainly:

- **openusage** ships as a signed, notarised universal DMG with in-app Sparkle updates and a Homebrew cask. aibars builds from source on your machine and has no update mechanism at all. It still has two things aibars does not: a one-shot CLI, and a loopback HTTP API other tools can read. Its global keyboard shortcut is no longer one of them — aibars has one now, and it is opt-in rather than bound out of the box. openusage documents ten providers and needs macOS 15.
- **AIQuotaBar** ships a WidgetKit desktop widget. aibars has no widget: that needs a second target, and the menu bar is the point. Its 90-day heatmap is no longer an advantage — aibars draws one too, under the chart rather than in a window of its own.
- **ClaudeMeter** is still the most polished single-service option in the category. Its six menu bar icon styles are matched: aibars has six strip drawings too, and they generalise across all fifteen services rather than one. What ClaudeMeter has that aibars does not is the depth that comes of only ever having to be right about Claude.
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

Everything else is UserDefaults: which services are enabled, your appearance settings, the alert rules and their armed state, your budgets, the six-hour sample rings behind the forecast, and the watermarks that let Claude Code's index re-read only what has been appended since last time. The global shortcut is stored under `aibars.hotkey.*` rather than with the appearance settings, and that is load-bearing: the appearance domain is wiped once per generation of the look, so a shortcut filed there would be silently unbound by a release that only moved a default colour, with no symptom but a keystroke that stops doing anything.

The local sources are read, never written. Claude Code's transcripts and OpenCode's database belong to those tools; aibars reads them where they are, copies OpenCode's database to a temporary file before querying it so it never contends with a live one, and deletes nothing.

No usage data leaves your Mac, there is no server, no telemetry and no analytics.

## Settings

- **Services** — connect, sign out, name an account, show or hide a service, a per-browser list of the sessions aibars can see with an Unlock button for the locked ones, and the two local sources with where each one reads from
- **Appearance** — five presets (Comfortable, Compact, Minimal, Dashboard, Monochrome) over sections for Size, Rows, What each row shows, Usage meter, The list and Menu bar, with a live preview and a Reset that puts everything back to how it shipped
- **History** — the chart, its range, the ninety-day grid, the per-day table, and the three things you can do to an archive: stop adding to it, take a copy, throw it away
- **Spend** — what each service says it cost, a cap per service and one overall, and the two warning levels
- **Alerts** — the alert switch, both thresholds, the reset announcement, whether the rows carry the pace claim, macOS's permission state and the last five alerts with whether they were delivered
- **General** — launch at login, the global shortcut that opens the panel, and the refresh interval: 30 seconds, 1, 5, 15 or 30 minutes
- **About** — version and links

The menu bar strip is configured under Appearance → Menu bar: which of the six drawings it uses, how many services it carries (one to three, where the drawing can carry more than one), its height (10–16pt), and whether it spends colour — monochrome, which keeps it a template image so the bar gives it its own light, dark and vibrancy treatment; colour only above the warning threshold; or colour on every figure.

Every preview in that pane is the real thing. The six style chips each carry the status item's own view, not a picture of one, and they take the live colour setting, so moving the colour picker moves all six. The strip preview goes through the same width fit the bar does, so it drops a segment exactly where the bar would. The panel preview is measured by the same `RowGeometry` a panel row is. A preview that disagrees with the thing it previews is worse than no preview, so there is one copy of that arithmetic and both call it.

Two settings have no control of their own and are set only by a preset, which is worth knowing before you go looking for them: whether brand marks carry their own hue — off under Monochrome, on everywhere else — and whether the header's summary reads the busiest service or the average across them, which is the average under Dashboard and the busiest under the other four.

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
│   ├── System/                 launch at login, the global shortcut, the defaults domain
│   ├── Views/                  design tokens, SwiftUI views, connect window, settings window
│   │   └── StripStyles/        one file per menu bar drawing
│   └── AppState.swift          AppState (service registry, polling) + AnyUsageProvider
├── SourcesApp/                 aibars app target (thin wrapper)
│   ├── aibarsApp.swift         @main + MenuBarExtra scene + the status item's strip
│   └── aibars.entitlements     Network client; sandbox off (reads browser cookie stores)
├── Resources/Assets.xcassets/  the app icon, cut from AppIconArt by ZZAppIcon
└── Tests/                      XCTest for parsers, policy, forecast, geometry and layout
```

The split exists so the app can ship with `@main` while unit tests run against the framework without bootstrapping the UI. The decisions worth testing are kept out of the views, and that now covers most of the visual system too: `UsageForecast`, `ThresholdPolicy`, `BudgetPolicy`, `HistoryQuery`, `RowGeometry`, `MeterGeometry`, `AppMarkGeometry`, `SparklineLayout`, `HeatmapBand`, `PanelFilter`, `PanelKeyboard`, `StripFit` and `MenuBarStripContent` are pure functions over their inputs, with no app state, no I/O and no notification centre in them. A row's height, a rail's width, where a reading becomes a length, which cell a day falls in, what a keystroke does and which segment the strip drops are all things a test can assert rather than a person eyeball. There are 1,608 of those tests, 6 of them skipped unless you ask for the harnesses that write files — the panel renders and the app icon; `make test` runs them in a little under two minutes. Two more skip on a machine with no Chromium cookie database — which is what a fresh CI runner is — so eight skipped there is the healthy number, not a regression.

Testing the arithmetic is not enough, and that was learned the hard way: every height defect here has been a correct calculation with a drawing that disagreed with it, sitting behind assertions that all passed. So the suite also hosts real `ProviderRow`s in an `NSHostingView` and measures what they actually draw, then asserts that the drawn height equals the reserved one and that nothing lands outside the panel's frame. A reservation with no drawing behind it is worse than none, because it reads as coverage.

Two things about *what* is swept, both learned from defects that hid in the gap. Every state a row can be in means every state, not the three a launch passes through: waiting, reporting, failed, a service reporting no quota at all, and — the one that was missing — a row that has reported and whose session then dies, which is precisely the state the reservation is written to protect and the one nothing had ever drawn. And the settings are swept as themselves rather than through the presets that pin them: a preset fixes the meter style, the further-window style, amounts and countdowns in one go, so five presets sample five points of the thirty-six those four axes span, and the two that a preset never visits are the two nothing measures.

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
                // The reset earns the countdown. The window's own length is
                // recorded and nothing draws it today — the pace riser it was
                // added for is gone — so supply it where the provider states
                // it and never infer it.
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
3. Give it a logo — either add a `BrandMark` entry in `Sources/Brand/BrandMarks.swift` (single-path SVG data plus its view box, 24×24 for simple-icons glyphs) or drop an image named `logo-myprovider` into an asset catalog. Without either, the row falls back to a lettermark, in the panel's mark grey rather than in `accentColor` — a letter has no brand hue to lend, and inventing one for it would be the one place colour on a row meant something other than "live". The strip keys its mark off `serviceID`, so a service with no glyph is a single letter at 13pt.
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
- ~~A global shortcut that opens the panel~~ — done, opt-in, over Carbon so it needs no Accessibility permission
- ~~A 90-day heatmap~~ — done, under the chart in the History pane
- ~~More than one drawing for the menu bar strip~~ — done: six, across all fifteen services
- ~~Find a row without reaching for the mouse~~ — done: type to filter, arrows and Return to act
- ~~A pace claim that cannot resize the panel~~ — done, by folding it onto the caption rather than by reserving a line for it
- ~~Not saying "resets in 25m" twice on the one row that can~~ — done: the pace sentence drops the half the countdown already carries
- ~~Something better than empty rungs under "One line per window"~~ — done: an unfilled rung draws the panel's own hairline where a window's label would start, and Dashboard reserves three of them rather than six
- ~~An application icon~~ — done: the mark on a graphite tile, cut from `AppMarkGeometry` so it cannot drift from the mark in the menu bar
- Antigravity, Devin and Pi, once their endpoints have been verified against a live account
- A signed, notarised build and some way to update one, which is the largest single gap against the closest rival. Building from source is the only route today
- A one-shot CLI and a local read-only HTTP endpoint, which is what openusage has and aibars does not. The providers are already a framework with no UI in them, so this is packaging rather than new reading
- Saying in words that an account at 100% with extra usage switched on is not actually blocked. The overage spend is already read and shown; the sentence beside a full meter is not there yet
- A switch for brand-mark colour of its own, instead of it being reachable only by taking the whole Monochrome preset
- Swift Charts for the history view, if and only if the floor ever moves to macOS 14 — every interactive API worth adopting it for arrived there, and the hand-drawn chart is at least visible to VoiceOver
- Not planned: a WidgetKit widget. It needs a separate target, and the menu bar is the point
- Not planned: spending a Codex reset credit from the menu bar. Reading an account is not the same as buying from it
