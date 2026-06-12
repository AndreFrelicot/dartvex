# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-06-12

### Added

- `ConvexBetterAuthProvider` accepts an `initialSessionToken` so a session
  token persisted from a previous run can be restored across process restarts
  via `loginFromCache()`. Previously the provider had no public way to seed
  the persisted token, so the documented persistence flow could not drive the
  provider-based `withAuth` restore.

### Fixed

- `BetterAuthClient.getSession()` now treats 401/403 as an expired or absent
  session while preserving non-auth HTTP failures as typed Better Auth
  exceptions, so transient 5xx responses are not collapsed into "no session".
- `BetterAuthClient.forgotPassword()` now calls Better Auth's official
  `/request-password-reset` endpoint instead of the obsolete
  `/forget-password` path.
- `BetterAuthClient` now preserves transient `/api/auth/convex/token` HTTP
  failures as retryable Better Auth exceptions instead of collapsing them into
  expired-session errors.
- Convert malformed 200 sign-in, sign-up, get-session, and magic-link response
  bodies into typed Better Auth errors instead of raw cast or decode exceptions.
- Guard the nested `user`/`session` fields of a 200 response: a non-object
  value now surfaces as a null session (or empty user fields) instead of a raw
  `TypeError`.
- Guard malformed nested Better Auth user scalar fields so non-string `id`,
  `email`, or `name` values do not throw raw cast errors.
- Convert malformed Convex token endpoint responses into typed session-expired
  errors instead of raw cast or decode exceptions.
- Clarify missing session-token errors with Flutter web CORS guidance and
  document that cookie fallback is native-only.
- Do not reject successful 200 Better Auth responses merely because they
  include informational `message` or `error` fields.
- `ConvexBetterAuthProvider.login()` now reuses the session created by
  `signUp()` when the credentials still match, avoiding an unnecessary
  duplicate sign-in request after account creation.
- `ConvexBetterAuthProvider.logout()` now clears cached session state even if
  the Better Auth sign-out request fails.
- Removes diagnostic prints that could expose Better Auth URLs, headers,
  cookies, request bodies, or tokens.

### Changed

- Require `dartvex` `^0.2.0`.
- `BetterAuthClient` now constructs its default HTTP client through the
  core's `createDefaultHttpClient()`, so auth requests share the platform
  transport installed by `dartvex_flutter` (NSURLSession on iOS/macOS). An
  explicitly provided `httpClient` behaves exactly as before.

## [0.1.3] - 2026-04-30

### Improved

- Refreshed README metadata, logo links, installation snippets, and package
  example code for pub.dev.

## [0.1.2] - 2026-03-21

### Improved

- Added comprehensive dartdoc comments on all public API
- Added example file for pub.dev scoring

## [0.1.1] - 2026-03-21

### Added

- Password recovery helpers with `forgotPassword()` and `resetPassword()`
- Magic link helpers with `sendMagicLink()` and `verifyMagicLink()`

### Fixed

- Better Auth magic link sign-in endpoint handling

## [0.1.0] - 2026-03-15

### Added

- Better Auth adapter for dartvex
- Email/password authentication
- Session management
- JWT token forwarding
