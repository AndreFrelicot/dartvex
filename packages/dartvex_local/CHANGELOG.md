# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `ConvexLocalClient.reset()` clears the queue (rolling back its optimistic
  patches), the recorded ID remaps, and the cache, in that order. Call it on
  an explicit sign-out or user switch; the client never clears anything on
  its own when the auth state changes. The identity caveats are documented on
  `ConvexLocalClient` and in the README.
- `LocalClientConfig.onConflict`, so conflicts from a replay that starts while
  the client opens are not missed.
- `LocalMutationConflict.pendingMutationId` and `operationId`, to correlate a
  conflict with the `LocalMutationQueued` result of the dropped mutation.
- `LocalRemoteQuerySuccess.isSeed`. `ConvexRemoteClientAdapter` sets it on the
  value the core client delivers from its own local state when a
  subscription starts.
- `JsonValueCodec` round-trips the Convex commit-timestamp placeholder
  (`{"$commitTs": null}`, Convex 1.43+). The value is kept as the core
  codec decodes it, or as the raw `{"$commitTs": null}` map when the core
  codec does not model it.

### Changed

- `currentConnectionState` is `online` only while the remote connection is
  established. A connecting or reconnecting remote now reports `offline`
  instead of `online`, matching when mutations are actually sent directly.
- In auto mode, `query()` no longer waits without bound while the remote is
  not connected: it returns the cached value right away, and without one
  waits at most `refreshQueryTimeout` before throwing a `TimeoutException`.
  While connected, behavior is unchanged.
- Several `LocalMutationHandler`s can now be registered for the same
  mutation; their patches are applied in registration order. Handlers are
  matched by canonical mutation name (`tasks.js:create` matches
  `tasks:create`). Previously only the last handler per raw name was used.
- Local-to-server ID remaps are kept after the queue drains and are applied to
  direct sends as well, so a local ID still held by the cache or app state is
  sent as its server ID. `clearQueue()` and `reset()` discard them.
- Post-replay cache refreshes run once per distinct target after the replay
  loop, and replay updates the in-memory queue instead of reloading the whole
  persisted queue after every step.
- Docs: `mutate` and `LocalMutationFailed` now state that handler, patch and
  storage failures while queueing are thrown, and that handler patches only
  apply to queued mutations (not to direct sends while online). `dispose`
  documents that caller-supplied storage is always closed and the remote
  client only with `disposeRemoteClient`.

### Fixed

- Fixed a new Dart 3.13 analyzer warning (`unawaited_return_in_try_block`) in
  `query()`; a failing cache write after a remote read also skipped the
  method's error handling.
- A direct `mutate()` in flight when the connection dropped held the FIFO
  mutate chain until reconnect, so every later `mutate()` (even after
  switching offline) waited unpersisted. The chain is now released when the
  remote leaves `connected` or the client is forced offline; later calls are
  queued, and replay waits for the in-flight request first, so call order is
  kept.
- Replay no longer drops queued mutations as conflicts when the
  `ConvexClient` is closed or disposed, or hits a fatal error: the mutation is
  kept, and replay stops until the remote reconnects. The adapter reports a
  closed client as `disconnected`, and replay stops as soon as the remote is
  no longer connected.
- Cancelling a subscription and immediately subscribing to the same query
  left the new subscriber without live updates and leaked its remote
  subscription.
- `setNetworkMode(auto)` no longer waits for the whole replay, so a following
  `setNetworkMode(offline)` takes effect (and stops replay) right away.
- A mutation queued while connected (after a retryable failure of the direct
  send, or behind an in-flight direct send) is now replayed without waiting
  for the next reconnect.
- The post-replay refresh no longer stores the core client's stale
  after-unsubscribe seed as the server value, which could drop the
  just-synced write from the cache.
- `Uint8List` (bytes) arguments were turned into plain integer lists during ID
  remapping and in persisted optimistic targets, so replayed bytes arguments
  were sent wrong and targets with bytes arguments got the wrong cache key.
- The remote connection state is re-read after the queue loads on open, so a
  connection established during an asynchronous storage load is not missed.
- An optimistic patch on a live query whose cache entry was expired or pruned
  by the cache policy (or cleared) now builds on the value subscribers last
  received instead of replacing it.
- A new subscriber to a query that other subscribers already receive gets the
  latest event, including remote errors (which are not cached) and values
  whose cache entry is gone.
- Storage failures right after the server committed a replayed mutation no
  longer roll it back, report a conflict, or re-send it; the local bookkeeping
  is retried. Other storage errors during replay schedule a retry instead of
  stalling the queue until the next reconnect.
- Remote error events, optimistic queueing, rollbacks and cached-snapshot
  emissions are serialized per query key with remote snapshot writes, so
  asynchronous storage cannot reorder them.
- A cache write failure no longer swallows remote results: live subscribers
  still receive them and `query()` returns them. Storage errors are logged at
  warning level.
- `clearCache()` followed by `clearQueue()` (or a later replay conflict) no
  longer writes the cleared values back from rollback snapshots.
- Rolling back a dropped replayed mutation uses its latest rollback baseline,
  including rebases from remote snapshots received during the round trip.
- A mutation left marked `replaying` by a crash or a dispose mid-replay is
  reset to `pending` when the client opens.

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

- Remote snapshot writes and their pending-patch rebases are now serialized
  per query key. Two rapid remote results for the same query used to
  interleave those multi-await spans, and when their rebase iterations
  diverged (a replay dropping a pending mutation mid-flight) the older
  event's rebased value could land last — leaving a stale value in the cache
  and as the subscribers' latest emission until the next remote event.
- Caller-provided args are now deep-snapshotted at the `query`, `subscribe`,
  `mutate`, and `action` entry points. A `LocalQueryDescriptor` key is
  recomputed from its stored args on every use, and the previous shallow copy
  shared nested values with the caller — so mutating a nested value after
  subscribing made the recomputed key diverge, orphaned the query state on
  cancel, and leaked its remote subscription. Concurrent `mutate` calls also
  snapshot before waiting on the FIFO mutation chain, so a later caller-side
  args mutation cannot alter a queued call that has not started yet.
- Disposing the client while a `setNetworkMode(LocalNetworkMode.offline)` or
  `clearQueue` call was emitting cached snapshots no longer routes an event
  into a just-closed subscription controller, which failed the in-flight
  call's future with "Cannot add new events after calling close". Dispose now
  clears the subscription registry before closing its controllers, and the
  emission loops stop once the client is disposed.
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
- A synchronous `LocalRemoteClient.subscribe` failure is now reported as a
  local query error event instead of escaping from `ConvexLocalClient.subscribe`
  after local subscription state has already been registered. The returned
  local subscription remains cancellable.
- Raw errors emitted by a remote query stream now count as remote events before
  they are surfaced locally, so a delayed cache seed cannot overwrite the
  remote error with stale cached data.
- Errors emitted by a custom `LocalRemoteClient.connectionState` stream are
  now logged and treated as a remote disconnect instead of surfacing as
  unhandled zone errors while leaving the local client marked online.
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
