# Changelog

All notable changes to aibars are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
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
