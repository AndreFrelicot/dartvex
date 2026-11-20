# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-11-20

### Changed

- Requires `dartvex` ^0.4.2, aligned with the other Dartvex packages (0.4.2
  only changes documentation; the network-outage fix this adapter relies on
  shipped in 0.4.1).

## [0.1.0] - 2026-11-20

### Added

- `ConvexAuthSessionProvider`, an `AuthProvider` for Convex Auth
  (`@convex-dev/auth` 2.0) sessions. It starts a session from a sign-in
  mutation or an adopted token bundle, then refreshes it through
  `refreshSession` and revokes it through `signOut`.
  - Concurrent refreshes share one request.
  - `onSessionChanged` reports every rotation, so the app can persist it. It
    may be asynchronous: saves run one at a time, in order; a new session is
    handed to the Convex client only once saved, and `logout()` completes
    once the stored session was removed. `sessionSaved` completes when the
    queued saves are done. A save that failed is made again at the next
    change, and `logout()` throws when the stored session could not be
    removed (calling it again retries the removal). Several `logout()` calls
    made at once are one logout: one sign-out request, one removal, and the
    same result for every caller.
  - A background refresh is tied to the session it refreshes: when the
    server reports that session gone, a `login()` to another one that is
    still in flight goes on.
  - The provider revokes a session only when it is another server session
    than the one in use (`ConvexAuthSession.sessionId`), so adopting a later
    rotation of the current session keeps it alive. A staged session that
    another `adoptSession` or a `logout()` discards is revoked.
  - `onBackgroundError` receives the errors of `onSessionChanged` and failed
    background revocations.
- `ConvexAuthSignIn`, with named constructors for the built-in
  username/password, email/password, password recovery and anonymous
  methods.
- `ConvexAuthHttpClient`, which calls Convex mutations over the HTTP API. A
  plain `http://` deployment URL is refused unless the host is the local
  machine or `allowInsecureHttp` is set.
- `ConvexAuthSession`, which converts the token bundle to and from JSON and
  exposes the `sessionId` of its access token.
- `ConvexAuthException`, `ConvexAuthSignInException` (the method's
  `userError` code) and `ConvexAuthSessionEndedException` (implements
  `AuthSessionEndedError`). Their `message` and `toString()` never contain
  text written by the server (a response body, a function's error message);
  that text is available as `serverMessage` and `logLines`. The `code` of a
  `ConvexAuthSignInException` is only set for a code-shaped `userError.error`;
  free text stays in `userError`.
- Requires `dartvex` 0.4.1, which keeps the session through a network outage
  (a retryable `ConvexAuthException` during a refresh) instead of signing the
  user out once the one-minute access token has expired. Validated on an
  Android device (Pixel 7 Pro): sign-up and sign-in errors, rotation,
  background, network loss, app killed during a session write, logout,
  revocation by another client and refresh token replay.
