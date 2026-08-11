# Security

aibars decrypts browser cookies and reads the login keychain, so security bugs are better
reported privately than in the public issue tracker.

## Reporting

Use GitHub's private reporting flow: [Report a vulnerability](https://github.com/AndrxwWxng/aibars/security/advisories/new).
If that page isn't available to you, email andrewwang123118@gmail.com instead.

This is a solo project, so there is no SLA. Best effort, and expect a first reply within a week.
Please don't open a public issue or a PR for a security bug until there's a fix.

## Versions

Only `main` is supported; there are no released builds yet.

## In scope

- Token handling in `Sources/Auth/KeychainStore.swift` and `Sources/Auth/SessionStore.swift`.
- The cookie readers: `ChromeCookieCrypto.swift`, `ChromeCookieExtractor.swift`,
  `SafariCookieExtractor.swift`, `FirefoxCookieExtractor.swift`.
- The login capture flow in `Sources/Auth/WebLogin.swift`.
- Any path that could send a session cookie somewhere it doesn't belong — `Sources/Auth/ProviderHTTP.swift`,
  or the user-configurable generic-provider endpoint.

## Out of scope

- The undocumented upstream provider endpoints. Those aren't ours; report them to the provider.
- Anything that needs the attacker to already have code execution or Full Disk Access on the
  user's Mac. At that point the browser cookies are readable without aibars.
