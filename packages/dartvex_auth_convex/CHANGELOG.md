# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0]

### Added

- `ConvexAuthSessionProvider`, an `AuthProvider` for Convex Auth
  (`@convex-dev/auth` 2.0) sessions. It starts a session from a sign-in
  mutation or an adopted token bundle, then refreshes it through
  `refreshSession` and revokes it through `signOut`.
  - Concurrent refreshes share one request, so a rotated refresh token is
    never sent twice.
  - `onSessionChanged` reports every rotation, so the app can persist it.
- `ConvexAuthSignIn`, with named constructors for the built-in
  username/password, email/password, password recovery and anonymous
  methods.
- `ConvexAuthHttpClient`, which calls Convex mutations over the HTTP API.
- `ConvexAuthSession`, which converts the token bundle to and from JSON.
- `ConvexAuthException`, `ConvexAuthSignInException` (the method's
  `userError` code) and `ConvexAuthSessionEndedException` (implements
  `AuthSessionEndedError`).
