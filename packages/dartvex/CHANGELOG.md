# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `ConvexClientConfig.connectTimeout` bounds the WebSocket handshake so a dead
  connection no longer hangs on the platform TCP timeout before retrying.
- Exponential reconnect backoff with jitter and server-reason classification,
  configurable via `initialBackoff`, `maxBackoff`, and `backoffJitter`.
- `ConnectivitySignal` and `ConvexClientConfig.connectivitySignal` to reconnect
  immediately when the device regains network connectivity, cancelling any
  in-progress backoff.
- Internal post-reconnect sync tracking (`hasSyncedPastLastReconnect`) across
  the local sync state, request manager, and base client: the client now knows
  when every query, auth update, and request issued before a reconnect has been
  confirmed by the server. This is package-internal groundwork for upcoming
  backoff-reset and auth-gating work and is not part of the public API.
- `ConnectionState.fatalError`, a terminal connection state entered when the
  server reports an unrecoverable error.
- `ConvexClientConfig.refreshTokenLeewaySeconds` (default `2`) controls how
  early a token is proactively refreshed before it expires.

### Changed

- Auth updates now gate the socket so requests can no longer be sent with
  absent or stale auth: the initial token fetch pauses the socket (buffering
  query-set changes and mutations, replayed together once the token is applied),
  and a reauth triggered by an `AuthError` stops the socket, fetches a fresh
  token, and restarts so it is replayed on a clean connection. Mirrors the
  official client's pause/resume and stop/restart auth gating.
- Auth token refresh is now scheduled from the token's own lifetime
  (`exp - iat`) minus `refreshTokenLeewaySeconds`, instead of from the device
  wall clock (`exp - now - 60`). Refresh timing is now immune to device clock
  skew; tokens without an `iat` claim fall back to the wall clock, and the
  delay is capped at 20 days.

- `reconnectBackoff` now defaults to empty, selecting the exponential backoff
  model. Provide an explicit non-negative schedule to keep fixed delays.

### Fixed

- Reconnect backoff now resets only after the client has re-synced every query,
  auth update, and request that predated the reconnect, instead of on every
  Transition or response. A server that repeatedly drops the connection before
  the client proves itself now keeps backing off instead of hammering it.
- An unrecoverable server `FatalError` now terminates the connection — pending
  requests fail, the connection state becomes `fatalError`, and no reconnect is
  attempted — instead of triggering a reconnect that could loop indefinitely.

## [0.1.5] - 2026-05-13

### Fixed

- Throws a clear error when a storage URL resolver returns `null` for a
  missing storage object.
- Aligns `TransitionChunk` handling with the current Convex protocol, including
  raw chunk payloads, zero-based part ordering, and invalid-chunk reconnects.
- Treats protocol `Ping` as a transport heartbeat without sending client
  protocol messages in response.
- Hardens auth refresh against stale token fetches, stale `AuthError` messages,
  and refresh scheduling that reused cached tokens.
- Schedules auth refresh from JWT expiration even when the token omits `iat`.
- Adds one-shot query timeout cleanup and safer disposal of temporary
  subscriptions.
- Rejects invalid Convex JSON field names and finite `$float` encodings.

### Added

- `ConvexClientConfig.queryTimeout`.
- `ConvexStorage.getFileUrl(..., useAction: true)` for action-based URL
  resolvers.

## [0.1.4] - 2026-04-30

### Added

- `ConvexClientConfig.connectImmediately` to defer opening the WebSocket until
  the first backend operation, auth update, or explicit reconnect.
- Structured query error payloads and server log lines on `QueryError` and
  one-shot `ConvexException` failures.
- Client protocol metadata fields for Convex component paths and auth
  impersonation metadata.
- Transport close diagnostics in WebSocket error logs.

### Fixed

- Replays safe queued requests after reconnect, including unsent actions and
  mutations awaiting their read-your-writes transition.
- Preserves pending request failures on dispose instead of leaving futures
  unresolved.
- Avoids logging structured Convex error payloads from failed requests.

## [0.1.3] - 2026-03-22

### Added

- `ConvexClient.reconnectNow(String reason)` — public method to force an immediate WebSocket reconnect, bypassing the backoff timer.

## [0.1.2] - 2026-03-21

### Improved

- Added comprehensive dartdoc comments on all public API
- Added example file for pub.dev scoring

## [0.1.1] - 2026-03-21

### Added

- Structured opt-in logging via `DartvexLogLevel`, `DartvexLogEvent`, and `DartvexLogger`
- `ConvexClientConfig` logging hooks for request, auth, storage, and transport diagnostics

## [0.1.0] - 2026-03-15

### Added

- Pure Dart Convex sync client
- WebSocket protocol implementation
- Read-your-writes mutations
- Multi-platform WebSocket (native + web)
- Auth framework with pluggable providers
- File storage helpers (ConvexStorage)
- One-shot query (queryOnce)
- Reconnection with exponential backoff
- Transition chunk reassembly
- Special value encoding
