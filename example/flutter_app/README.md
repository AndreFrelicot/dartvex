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

Demo auth token at startup — capture the token in a shell variable first (it is
~400 characters; pasting it directly on the command line is fragile, see
[Troubleshooting](#troubleshooting)):

```bash
TOKEN="$(cd ../convex-backend && npm run -s token)"
flutter run \
  --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud \
  --dart-define=CONVEX_DEMO_AUTH_TOKEN="$TOKEN"
```

## Standalone builds (test on a device)

`--dart-define` values are compile-time constants baked into the binary, so pass
them to `flutter build` (not only `flutter run`). The resulting artifact runs on
a device with no `flutter`/terminal attached.

```bash
cd example/flutter_app
TOKEN="$(cd ../convex-backend && npm run -s token)"

# macOS (.app — no signing needed for local runs)
flutter build macos --release \
  --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud \
  --dart-define=CONVEX_DEMO_AUTH_TOKEN="$TOKEN"
open build/macos/Build/Products/Release/convex_flutter_demo.app

# Android (installable APK)
flutter build apk --release \
  --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud \
  --dart-define=CONVEX_DEMO_AUTH_TOKEN="$TOKEN"
# install: adb install -r build/app/outputs/flutter-apk/app-release.apk

# iOS (requires Apple signing; a release build installs standalone on a paired device)
flutter run --release -d <device-id> \
  --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud \
  --dart-define=CONVEX_DEMO_AUTH_TOKEN="$TOKEN"
```

> A baked `--dart-define` value is recoverable from the binary (it is a
> compile-time constant — e.g. `strings` on the artifact reveals it). That is
> fine for the demo JWT and the deployment URL, but never bake a real secret
> into a client build.

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
- a dedicated `Files` tab showing Convex file storage upload and a live gallery:
  - web renders signed storage URLs directly
  - native builds also show disk cache and offline image fallback

## Auth modes

The `Auth` tab includes a segmented button to switch between two auth modes.
Both modes drive the same `ConvexClientWithAuth` wrapper — only the
provider implementation differs.

### Demo mode (default)

Uses `DemoAuthProvider`, a deterministic in-memory provider with no external
service. Public screens and Better Auth work without this provider, but Demo
mode requires a JWT generated locally from the example backend key material.

1. Configure the demo JWT provider in Convex:

```bash
cd ../convex-backend
npm run demo:key
```

2. Run the printed `npx convex env set DEMO_JWKS ...` command. This publishes
   only the public JWKS to Convex. The private key remains in gitignored `.env`.

3. Run Flutter with a freshly generated token (capture it in a shell variable —
   see [Troubleshooting](#troubleshooting)):

```bash
cd ../flutter_app
TOKEN="$(cd ../convex-backend && npm run -s token)"
flutter run \
  --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud \
  --dart-define=CONVEX_DEMO_AUTH_TOKEN="$TOKEN"
```

If `CONVEX_DEMO_AUTH_TOKEN` is omitted, the Auth tab stays available but Demo
login/reconnect actions are disabled and the app shows a setup notice. This is
intentional: the repo does not ship a default private key or bundled JWT.

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
npx convex env set BETTER_AUTH_SECRET "$(openssl rand -base64 32)"
```

3. If you host the Flutter web build somewhere other than localhost, allow that
   origin:

```bash
npx convex env set BETTER_AUTH_TRUSTED_ORIGINS=https://your-web-demo.example
```

Flutter web on `localhost` or `127.0.0.1` is allowed automatically.

4. Deploy:

```bash
npx convex dev   # or npx convex deploy
```

5. Run the demo (no extra `--dart-define` needed beyond `CONVEX_DEMO_URL`):

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
| `CONVEX_DEMO_AUTH_TOKEN` | Demo mode only | JWT generated by `example/convex-backend`; not needed for public screens or Better Auth |

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

## Files demo notes

Upload and the live `files:list` gallery work on web and native targets. On web,
the demo resolves signed Convex storage URLs and renders them with
`Image.network`; disk-backed file cache and offline image fallback are
native-only, so the extra image-widget/cache variants are hidden on web.

## Troubleshooting

- **`zsh: file name too long`, or `Target file "…" not found` when launching** —
  the `--dart-define=CONVEX_DEMO_AUTH_TOKEN=…` argument got mangled. The demo JWT
  is ~400 characters; a broken line continuation (a space after a trailing `\`)
  turns it into a positional argument that the shell or Flutter then misreads.
  Fix: put the token in a variable first (`TOKEN="$(…)"`) and pass `"$TOKEN"`, or
  run the whole command on a single line.
- **Auth tab shows "Demo token missing"** — `CONVEX_DEMO_AUTH_TOKEN` did not reach
  the build (usually the issue above). Public tabs and Better Auth do not need it.
- **`./generate_bindings.sh: permission denied`** — run it via
  `bash example/generate_bindings.sh`, which works regardless of the file's
  executable bit.

## Regenerate the typed API

From the repo root:

```bash
bash example/generate_bindings.sh
```
