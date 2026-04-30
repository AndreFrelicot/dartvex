# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
