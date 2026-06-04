# dartvex test suite

The full suite is the parity regression suite — run it with:

```sh
dart test
```

Most tests are hermetic and drive a real `ConvexClient` over the in-memory
`test_helpers/mock_web_socket_adapter.dart`, so no backend is required. Two
groups talk to (or stand in for) a real deployment and are **tagged** so they
can be selected or excluded as a unit:

```sh
dart test -x integration   # skip live-deployment tests (suggested for CI)
dart test -t conformance    # only the protocol conformance suites
dart test -t integration    # only the live-deployment tests
```

Tags are declared in `dart_test.yaml`. The `integration` tests self-skip when
`CONVEX_DEPLOYMENT_URL` is unset, so they never fail without a backend.

## Workstream → tests

Parity was delivered as the workstreams below; each row lists the tests that
guard it (regression coverage).

| Workstream | What it covers | Tests |
|------------|----------------|-------|
| WS0a — reconnect | connect watchdog, connectivity-triggered reconnect, jittered/classified backoff | `transport/ws_manager_test.dart`, `transport/web_transport_test.dart` |
| WS4a — sync tracking | `hasSyncedPastLastReconnect` across local state / requests / base client | `sync/local_state_test.dart`, `sync/request_manager_test.dart`, `sync/base_client_test.dart` |
| WS0b — reconnect correctness | backoff reset gated on re-sync; `FatalError` → terminate | `transport/ws_manager_test.dart`, `sync/base_client_test.dart`, `client_test.dart` |
| WS1 — auth parity | socket pause/stop gating, exp−iat scheduling, `AuthRefreshing`, stale-auth guard, admin auth | `auth_manager_test.dart`, `auth_test.dart`, `client_test.dart` |
| WS2 — optimistic updates | overlay set/get/replay, drop-on-transition, rollback | `sync/optimistic_updates_test.dart`, `sync/base_client_test.dart`, `client_test.dart` |
| WS3 — reactive pagination | page chaining via journals, reactive page updates, splitting, reset | `sync/paginated_query_test.dart`, `client_test.dart` |
| WS4b — rich connection state | `ConnectionStatus` (inflight/retries/sync), monotonic clock for `Connect.clientTs` + transit | `transport/monotonic_clock_test.dart`, `transport/ws_manager_test.dart`, `sync/request_manager_test.dart`, `client_test.dart` (the `connection status` group) |
| WS5 — conformance | wire-message + transition conformance (fake transport, CI-safe) and the live counterpart | `conformance/protocol_conformance_test.dart`, `conformance/live_backend_conformance_test.dart` (`conformance`, `integration` tags) |

## Already-at-parity baselines

| Area | Tests |
|------|-------|
| Value codec / protocol encoding | `protocol/value_codec_test.dart`, `protocol/protocol_test.dart` |
| Storage / file URLs | `storage_test.dart` |
| One-shot queries | `query_once_test.dart` |
| Logging | `logging_test.dart` |
| Public API surface | `public_api_test.dart` |

## Live deployment tests

`integration/*` and `conformance/live_backend_conformance_test.dart` run against
a real backend (the demo lives in `example/convex-backend`, runnable with
`npx convex dev`). Point the env vars at it, e.g.:

```sh
CONVEX_DEPLOYMENT_URL=https://your.convex.cloud \
CONVEX_TEST_QUERY=messages:list \
CONVEX_TEST_MUTATION=messages:send \
dart test -t integration
```
