# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-11-05

### Fixed

- `loginFromCache()`'s `'No cached Better Auth session.'` and
  `'Better Auth session expired.'` errors (still `StateError`s) and
  `BetterAuthSessionExpiredException` implement `AuthSessionEndedError`: a
  restore of an expired session on an authenticated `ConvexClientWithAuth`
  now signs out instead of keeping the dead session as authenticated.
- Timed-out requests are aborted (`http.AbortableRequest`) instead of only
  no longer being awaited, so a sign-in that times out cannot still create a
  session in the background. Requires `http` ^1.5.0.
- `verifyMagicLink()` on Flutter web follows Better Auth's error redirect
  and reads the error code from the final URL: package:http's `BrowserClient`
  fails a request that does not follow redirects, so the code path that
  reads `INVALID_TOKEN`/`EXPIRED_TOKEN` was unreachable in browsers.
- Compatibility with `@convex-dev/better-auth` 0.12.7+ / 0.13: an emptied or
  expired `convex_jwt` cookie (`Max-Age=0`, empty value, or a past `Expires`)
  on sign-in, sign-up and magic-link responses is no longer returned as the
  Convex token (which left native clients with an empty JWT); the client now
  falls back to `GET /api/auth/convex/token`. When a cookie is set several
  times in one response, the last occurrence wins. The same rule applies to
  the `session_token` cookie fallback.
- `BetterAuthClient.getSession()` returns `null` again when Better Auth
  answers HTTP 200 with a JSON `null` body, which is how it reports a missing,
  expired or revoked session. Other malformed bodies still throw. As a result
  `ConvexBetterAuthProvider.loginFromCache()` now reports an expired session
  as the documented `StateError('Better Auth session expired.')` instead of a
  "not a JSON object" `BetterAuthException`.
- `loginFromCache()` clears the dead session token and cached session when
  Better Auth reports the session as expired, so it is not retried.
- Sign-up with email verification required (`{"token": null, "user": ...}`)
  throws `BetterAuthEmailVerificationRequiredException`, and a sign-in that
  needs a second factor (`{"twoFactorRedirect": true}`) throws
  `BetterAuthTwoFactorRequiredException`, instead of a misleading
  "bearer() plugin / CORS" error or a session-expired error.
- A stale in-flight `loginFromCache()` (for example a token refresh) can no
  longer overwrite the session of a newer `login()`, `signUp()` or
  `logout()`; its result is discarded with a retryable `BetterAuthException`.
- `logout()` clears local state before sending the sign-out request (still
  clearing it when the request fails), so a `login()` started while sign-out
  is in flight is no longer wiped when it completes. A `login()` or
  `signUp()` superseded by a newer `logout()`/`login()` throws and signs its
  orphaned server session out in the background.
- Non-200 Better Auth responses keep the decoded error body as `data` (with
  the Better Auth `code`), and 5xx/429 responses are `retryable` on every
  endpoint, not only `get-session` and `/convex/token`.
- **Breaking:** network failures (`http.ClientException`) and request
  timeouts surface as retryable `BetterAuthException`s instead of raw client
  exceptions.
- `verifyMagicLink()` no longer follows Better Auth's error redirect; the
  `INVALID_TOKEN` / `EXPIRED_TOKEN` / `ATTEMPTS_EXCEEDED` code is reported as
  the exception's `code` (on web, read from the final redirect URL).
- `getSession()` uses the refreshed `convex_jwt` cookie from the
  `get-session` response when present, saving the `/convex/token` round-trip
  on native platforms.
- `BetterAuthException.toString()` (and subclasses) print their own type
  name and the Better Auth error code instead of `ConvexException(...)`.

### Added

- `BetterAuthClient(siteUrl: ...)` overrides the HTTP-actions origin for
  custom domains, local backends (`http://127.0.0.1:3211`) and self-hosted
  deployments, where it cannot be derived from `baseUrl`.
- `BetterAuthClient(basePath: ...)` for servers that mount Better Auth on a
  custom `basePath` (default `/api/auth`).
- `BetterAuthClient(requestTimeout: ...)`: **Breaking (behavior):** every
  request now has a timeout (default 30 seconds; `null` disables it).
- `BetterAuthException.code`, `BetterAuthEmailVerificationRequiredException`
  and `BetterAuthTwoFactorRequiredException`.
- `ConvexBetterAuthProvider.adoptSession()` to hand a session obtained
  elsewhere (for example from `verifyMagicLink()`) to the provider before
  `authedClient.loginFromCache()`.

### Changed

- `ConvexBetterAuthProvider.signUp()`'s `onIdToken` parameter is now optional;
  `signUp()` never authenticated the Convex client, call
  `authedClient.login()` afterwards (it reuses the sign-up session).
- **Breaking:** `ConvexBetterAuthProvider.logout()` now also clears the
  `email` and `password` fields, so a later `login()` cannot silently sign the
  previous user back in. Set credentials again before the next `login()`.
- README: sign out with `authedClient.logout()` instead of
  `authClient.signOut(...)` (which left the Convex client authenticated),
  present raw `BetterAuthClient` sign-in as an alternative to the provider
  flow rather than a step before it, document the native magic-link deep-link
  setup, the `loginFromCache()` error contract (`StateError` for an expired
  session is kept deliberately), `siteUrl`/`basePath`, and the Better Auth
  versions the example backend pins.

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
