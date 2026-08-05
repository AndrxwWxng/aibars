# Changelog

All notable changes to aibars are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Four more providers: Google Gemini, Grok, Perplexity and DeepSeek. Gemini, Grok and Perplexity read a session cookie; DeepSeek uses an API key from its platform console. Every endpoint here is undocumented except DeepSeek's, so each provider notes in-file how much of its response shape is confirmed.
- Chromium cookie decryption, which is what makes signing in through Chrome, Edge, Brave, Arc or Opera possible at all. The Safe Storage key comes from the login keychain, so the first read prompts for access.
- Per-row refresh and a link out to each service's own usage page, revealed on hover.
- Commit conventions in `CONTRIBUTING.md` plus a `.gitmessage` template.
- One-click sign-in: aibars hosts each provider's own login page in a window and captures the session cookie as soon as it appears, replacing the DevTools copy-paste flow. Every login window keeps a "paste a token instead" fallback.
- Real provider logos, drawn from single-path SVG data by a new SVG path parser (`Sources/Brand/`). Near-black marks flip to light on dark backgrounds. A bundled `logo-<providerID>` image overrides the built-in mark.
- Menu bar meter: one bar per service, tallest first, tinted only on the bars that are actually near their cap.
- `Sign in` button directly on a disconnected provider's row in the dropdown.
- Live menu bar preview in Settings → General.

### Changed
- Redesigned the dropdown: logo tiles, plan pills, gradient usage bars, compact `3h 12m` countdowns, and per-service secondary chips.
- Signing out now also clears the cookies aibars stored for that provider's domains.
- Copilot reports its seat as a status rather than a `1/1` quota, so an active seat no longer reads as 100% used.

### Fixed
- Provider rows stayed on "Sign in required" after a successful sign-in — the type-erased wrapper never refreshed its auth flag.
- Settings had no way to set the generic provider's usage endpoint, so it could never authenticate.

### Added (initial scaffold)
- Initial scaffold
- `aibarsCore` framework: models, auth, cookie extraction, providers, views
- `aibars` app target: SwiftUI menu bar app (macOS 13+)
- Five bundled providers: Claude, ChatGPT, Cursor, GitHub Copilot, MiniMax
- Cookie extraction for Safari, Firefox, Chrome, Edge, Brave, Arc
- Manual session token paste as a fallback
- Keychain-backed token storage
- Per-provider enable/disable, configurable refresh interval
- Three menu bar display modes (icon, percent, name)
- XCTest suite for parsers and formatters
- XcodeGen `project.yml`
- `Makefile` (`make build`, `make test`, `make run`, `make clean`)

## [0.1.0] - 2026-08-01

First open-source release.
