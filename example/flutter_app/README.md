# Dartvex Demo App

This Flutter app demonstrates the packages in this repo working together:

- `dartvex` for transport and auth
- `dartvex_codegen` for typed Dart bindings
- `dartvex_flutter` for runtime-aware Flutter widgets
- `dartvex_local` for local-first cache, offline queueing, and replay
- `dartvex_auth_better` for optional Better Auth (self-hosted) authentication

## Run

```bash
cd example/flutter_app
flutter pub get
flutter run \
  --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud
```

Optional auth token at startup:

```bash
flutter run \
  --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud \
  --dart-define=CONVEX_DEMO_AUTH_TOKEN="$(cd ../convex-backend && npm run -s token)"
```

## What the app shows

- public realtime query + mutation without auth
- private realtime query + mutation with provider-backed auth
- current viewer state
- connection state via `dartvex_flutter`
- action invocation via the generated API
- an `Auth` tab with a **Demo / Better Auth mode selector**:
  - **Demo mode**: deterministic `DemoAuthProvider` with login, cache restore,
    logout, forced reconnect, and provider diagnostics
  - **Better Auth mode**: self-hosted authentication running inside your Convex
    backend via `ConvexBetterAuthProvider` from `dartvex_auth_better`
    (requires `@convex-dev/better-auth` component; shows setup checklist if not configured)
- a dedicated `Local` tab showing:
  - cached query fallback
  - forced offline mode
  - queued offline mutations
  - optimistic local updates
  - replay when sync resumes

## Auth modes

The `Auth` tab includes a segmented button to switch between two auth modes.
Both modes drive the same `ConvexClientWithAuth` wrapper — only the
provider implementation differs.

### Demo mode (default)

Uses `DemoAuthProvider`, a deterministic in-memory provider with no external
service. No additional configuration is required.

Suggested manual flow:

1. Open `Auth`.
2. Tap `Login`.
3. Confirm the auth state changes to authenticated and the private feed/viewer
   become available.
4. Tap `Force Reconnect`.
5. Confirm the connection chip cycles through reconnecting and the auth
   diagnostics show another `loginFromCache()` call.
6. Tap `Logout`.
7. Tap `Login From Cache`.
8. Confirm the cached session restores without a visible login UI.

### Better Auth mode

Uses `ConvexBetterAuthProvider` from the `dartvex_auth_better` package with
a self-hosted auth backend running inside Convex. No external auth service
needed — credentials are stored in the Convex database.

#### Setup

1. Install the Better Auth component in the Convex backend:

```bash
cd example/convex-backend
npm install better-auth@1.5.3 @convex-dev/better-auth
```

2. Set the secret:

```bash
npx convex env set BETTER_AUTH_SECRET=$(openssl rand -base64 32)
```

3. Deploy:

```bash
npx convex dev   # or npx convex deploy
```

4. Run the demo (no extra `--dart-define` needed beyond `CONVEX_DEMO_URL`):

```bash
flutter run \
  --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud
```

If the Convex backend does not have the Better Auth component installed, the
app shows a setup checklist with the steps above.

#### `--dart-define` reference

| Key | Required | Description |
|-----|----------|-------------|
| `CONVEX_DEMO_URL` | Yes | Convex deployment URL |
| `CONVEX_DEMO_AUTH_TOKEN` | No | JWT for Demo mode startup auth |

## Local-first demo notes

The local-first tab uses `package:sqlite3` on native targets.

Requirements:

- a reachable `CONVEX_DEMO_URL`
- dependencies resolved successfully for the app and `dartvex_local`
- if `pub.dev` is blocked on your machine, use
  `PUB_HOSTED_URL=https://pub-web.flutter-io.cn flutter pub get`

Suggested manual flow:

1. Open the `Local` tab while online.
2. Let the public chat or tasks query load once.
3. Tap `Go offline`.
4. Send a public message or create / advance a task.
5. Confirm the UI updates immediately and the pending write counter increases.
6. Tap `Resume sync`.
7. Confirm the queue replays and the query source returns to remote data.

## Regenerate the typed API

From the repo root:

```bash
bash example/generate_bindings.sh
```
