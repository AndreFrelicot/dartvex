# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.4] - 2026-06-04

### Changed

- Require `dartvex` `^0.2.0`.
- Require Dart `^3.10.0` to align with the SQLite 3.x runtime dependency.

### Fixed

- Map the new terminal `dartvex` `ConnectionState.fatalError` to a disconnected
  local connection state, keeping the remote-client adapter's connection-state
  mapping exhaustive and analyzer-clean.
- Delivering a query event no longer throws when a subscriber cancels (or
  re-subscribes the same query) synchronously from its listener: the fan-out
  iterates a snapshot of subscribers and defers closing the subscription stream
  past the in-progress dispatch, fixing a `ConcurrentModificationError` and a
  "Cannot fire new event" state error.
- `SqliteLocalStore.close()` no longer deletes the database file's parent
  directory, which could remove unrelated files placed alongside it.

## [0.1.3] - 2026-05-13

### Fixed

- Queues auto-mode mutations immediately while the remote client is
  disconnected, and waits for a connected remote before replaying queued
  mutations.
- Uses the Convex value codec for local query keys and storage payloads so
  `BigInt`, bytes, and special floating-point values round-trip correctly.
- Queues retryable auto-mode mutations when the remote client is unavailable.
- Retains retryable replay failures for later retry instead of dropping queued
  mutations.
- Falls back to cached query data on retryable remote failures.
- Preserves structured remote query error data and server log lines in the
  local runtime adapter.

## [0.1.2] - 2026-04-30

### Improved

- Refreshed README metadata, logo links, installation snippets, and example
  code for pub.dev.
- Declared native platform support explicitly so pub.dev does not advertise web
  support for the SQLite-backed package.

## [0.1.1] - 2026-03-21

### Improved

- Added comprehensive dartdoc comments on all public API
- Added example file for pub.dev scoring

## [0.1.0] - 2026-03-15

### Added

- SQLite-backed query cache for offline fallback
- Offline mutation queue with ordered replay
- Optimistic updates via LocalMutationHandler
- Deterministic network mode control
- ID remapping during replay
- Connection state stream
