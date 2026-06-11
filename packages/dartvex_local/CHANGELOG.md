# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-06-12

### Changed

- Require `dartvex` `^0.2.0`.
- Require Dart `^3.10.0` to align with the SQLite 3.x runtime dependency.
- `CacheStorage` implementations must now provide `deleteCacheEntry`, because
  single-entry deletion is required for correct optimistic rollback. The
  optional `CacheStorageMaintenance` interface now only covers maximum-entry
  pruning.
- `QueueStorage` implementations must now provide
  `saveFailedLocalId`, `loadFailedLocalIds`, and `clearFailedLocalIds`, because
  replay must persist failed locally-generated IDs to keep dependent mutations
  from being sent with stale IDs after a restart.

### Fixed

- `setNetworkMode` transitions are now serialized. A mode change issued while
  the previous transition was still suspending or resuming remote
  subscriptions could interleave with it — re-attaching some queries
  mid-suspension while the rest were detached after the resume, leaving them
  unsubscribed (and silently stale) in auto mode.
- `dispose` and `setNetworkMode(LocalNetworkMode.offline)` no longer throw a
  `ConcurrentModificationError` when a subscription cancel that drops a
  query's last subscriber is in flight at the same time; the failed `dispose`
  also skipped closing the underlying storage.
- `clearQueue` now rolls back the discarded mutations' optimistic patches:
  every affected cached query is restored to its oldest pending rollback
  baseline (the last server-confirmed value) and subscribers are notified, so
  the cache no longer presents writes that will never be sent as authoritative
  data. An optimistic-only cache entry (one created from an absent baseline) is
  deleted and its subscribers receive an error event instead of a stale
  optimistic value.
- `PendingMutation.copyWith` can now clear replay error metadata explicitly via
  `clearErrorMessage`, avoiding stale errors when callers reset queue state.
- `ConvexLocalClient.mutate` now serializes calls in FIFO order, so concurrent
  mutations can no longer race the "send directly while the queue is empty"
  fast path and commit (or queue) out of call order. Mutations awaited
  sequentially are unaffected.
- The offline replay retry backoff now clamps its exponent before shifting, so
  it stays monotonic and never wraps after many consecutive failures (web uses
  32-bit left shifts).
- Replay no longer rewrites a queued mutation's args when id remapping leaves
  them unchanged, avoiding a redundant SQLite write per replayed mutation.
- Remote query loading events from `dartvex` are now handled explicitly by the
  local runtime adapter, keeping switches exhaustive while preserving cached
  local results until a remote success or error arrives.
- `LocalClientConfig.queryCachePolicy` can now expire stale cached query
  results and prune the SQLite query cache to a maximum entry count, preventing
  unbounded growth and arbitrarily old offline reads when configured.
- SQLite database handles are now closed if schema migration fails during
  `SqliteLocalStore.open` or `openInMemory`.
- Auto-mode mutations now queue behind any existing replay work instead of
  bypassing a non-empty offline queue and committing newer mutations before
  older queued ones.
- Drops queued mutations that still reference unresolved `local-*` IDs during
  replay, so dependents of a failed create are reported via `onConflict` instead
  of being sent to the backend with stale local IDs.
- Local ID replay remaps can now be captured from create mutations returning
  either a string id or an object containing `_id`/`id`.
- Local ID replay remaps now also rewrite `local-*` IDs used as object **keys**
  in a queued mutation's args, not just as values, so an offline mutation keyed
  by a freshly-created document is replayed against the real server ID. The
  unresolved-ID drop guard likewise inspects keys, so a dependent keyed by a
  failed create is dropped instead of sent with a stale local ID.
- Rolling back a dropped mutation now re-snapshots every surviving pending
  mutation's rollback baseline to the restored cache value, so dropping a second
  mutation that touches the same query can no longer resurface the first,
  already-dropped mutation when the best-effort post-drop server refresh fails.
- Replay now tracks actual locally generated IDs instead of treating every
  `local-<digits>-<digits>` shaped user string as an unresolved local ID, while
  persisting failed local IDs so dependents are still dropped correctly after a
  crash.
- Replay now rejects local-ID map-key remaps that would collide with an existing
  key after resolution, reporting the queued mutation through `onConflict`
  instead of silently dropping one of the map entries before sending to Convex.
- Stops in-flight replay cleanly during `dispose()`, preventing writes to closed
  SQLite stores or closed mutation streams after a delayed remote mutation
  returns.
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
- Queues auto-mode mutations immediately while the remote client is
  disconnected, and waits for a connected remote before replaying queued
  mutations.
- Uses the Convex value codec for local query keys and storage payloads so
  `BigInt`, bytes, and special floating-point values round-trip correctly.
- Queues retryable auto-mode mutations when the remote client is unavailable.
- Retains retryable replay failures for later retry instead of dropping queued
  mutations.
- Rolls back failed optimistic patches and permanently rejected queued mutations
  against the previous local cache value, so retryable or failed mutations do
  not leave stale optimistic query data visible after the error path runs.
- Rollback now deletes optimistic-only cache entries through every
  `CacheStorage` implementation, including custom stores that do not implement
  `CacheStorageMaintenance`.
- Falls back to cached query data on retryable remote failures.
- Preserves structured remote query error data and server log lines in the
  local runtime adapter.
- `ConvexLocalClient.openWithRemote` now respects
  `LocalClientConfig.disposeRemoteClient`, leaving caller-owned custom remotes
  alive by default and disposing them only when explicitly configured.

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
