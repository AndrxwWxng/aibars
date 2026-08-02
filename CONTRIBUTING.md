# Contributing

Thanks for taking a look. Here's how to get set up and submit a change.

## Setup

1. `brew install xcodegen`
2. `git clone https://github.com/aibars/aibars && cd aibars`
3. `xcodegen generate`
4. `open aibars.xcodeproj`

## Before you commit

- `make test` — all tests should pass
- `make build` — clean build with no warnings
- Don't commit any session tokens, API keys, or other secrets. The `Secrets.swift` path is in `.gitignore` for this reason.

## Filing an issue

- For a bug, include macOS version, provider, and a screenshot of the auth sheet error if relevant.
- For a feature request, describe the use case rather than the implementation.

## Adding a provider

See the [README](README.md#adding-a-new-provider) for the template.

The most common additions are: Perplexity, Windsurf, Cody, Replit, v0, Notion AI, Notion, JetBrains AI, Cody (Sourcegraph), Augment Code.

## Style

- 4-space indent, no tabs.
- One type per file unless they're tightly coupled (e.g. `UsageMetric` and `UsageData` together).
- Public APIs get `public` and a doc comment.
- `ProviderError` for any failure you surface to the UI. Don't throw `String` or `NSError` from a provider method.
- Use `ProviderNumber.coerce` for any JSON value that might be `Int` or `Double`.

## Architecture

```
┌─────────────────────────────┐
│  SourcesApp/aibarsApp.swift │  thin @main shell
└──────────────┬──────────────┘
               │ imports
┌──────────────▼──────────────┐
│        aibarsCore           │  framework
│ ┌─────────────────────────┐ │
│ │ Models                  │ │  UsageData, UsageProvider
│ ├─────────────────────────┤ │
│ │ Auth                    │ │  Keychain, cookie extractors, HTTP
│ ├─────────────────────────┤ │
│ │ Providers               │ │  one file per service
│ ├─────────────────────────┤ │
│ │ Views                   │ │  SwiftUI views
│ └─────────────────────────┘ │
└──────────────┬──────────────┘
               │ imported by
┌──────────────▼──────────────┐
│     Tests (XCTest)          │  parser/formatter tests
└─────────────────────────────┘
```

The `aibarsCore` framework contains everything that isn't `@main`. This lets XCTest link against the framework without bootstrapping the SwiftUI lifecycle.

## Release process

1. Bump `MARKETING_VERSION` in `project.yml`
2. Add an entry to `CHANGELOG.md`
3. Tag with `git tag v0.x.y` and push

## Code of conduct

Be kind. Disagreement is fine; rudeness is not.
