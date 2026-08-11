# Contributing

Thanks for taking a look. Here's how to get set up and submit a change.

## Setup

1. `brew install xcodegen`
2. `git clone https://github.com/AndrxwWxng/aibars && cd aibars`
3. `xcodegen generate`
4. `open aibars.xcodeproj`

## Before you commit

- `make test` — all tests should pass
- `make build` — clean build with no warnings
- Don't commit any session tokens, API keys, or other secrets. The `Secrets.swift` path is in `.gitignore` for this reason.

## Commit messages

Conventional Commits, in the imperative mood. `git config commit.template .gitmessage`
wires up a reminder of the rules in your editor.

```
<type>(<scope>): <summary in the imperative, lower case, no full stop>

<why the change was needed, and anything a reviewer could not infer from the diff>

<footers: Fixes #123, BREAKING CHANGE: …>
```

**Types** — `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`.

**Scopes** — the area touched: a provider id (`claude`, `cursor`), or one of
`auth`, `brand`, `menu`, `settings`, `models`, `http`, `project`.

Rules that matter:

- **Summary ≤ 72 characters**, imperative (`add`, not `added`/`adds`), no trailing period.
- **The body explains why**, not what. The diff already says what. If a workaround
  exists because an endpoint is undocumented or a shape is guessed, say so here —
  that is the context the next reader will not be able to reconstruct.
- **One concern per commit.** A provider addition and a UI change are two commits.
  A commit that needs "and" in its summary is usually two commits.
- **Every commit should build.** Don't split a change so finely that an intermediate
  commit fails `make build`.
- **Reference the issue** in a footer (`Fixes #12`), not in the summary.
- **Mark breaking changes** with a `BREAKING CHANGE:` footer explaining the migration.

Good:

```
fix(copilot): report an active seat as a status, not a full quota

The user endpoint has no numeric usage, so the seat was encoded as 1/1 and
every connected Copilot row read as 100% used — which pinned the menu bar
meter to its alert colour. A zero limit marks the metric as status-only.
```

```
feat(auth): decrypt Chromium cookie values

Reading the session out of the user's own browser only worked for Firefox,
which leaves cookies in plaintext. Chromium's key lives in the login keychain,
so the first read now prompts for access; declining falls back to pasting.
```

Not good — no scope, past tense, no why, two concerns in one:

```
Updated stuff and fixed the logos and added gemini
```

## Filing an issue

- For a bug, include macOS version, provider, and a screenshot of the auth sheet error if relevant.
- For a feature request, describe the use case rather than the implementation.

## Adding a provider

See the [README](README.md#adding-a-new-provider) for the template.

Commonly requested but not yet built: Windsurf, Cody (Sourcegraph), Replit, v0, Notion AI, JetBrains AI, Augment Code.

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
