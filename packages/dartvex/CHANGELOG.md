# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
