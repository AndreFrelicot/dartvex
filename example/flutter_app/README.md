# Dartvex Demo App

This Flutter app demonstrates the packages in this repo working together:

- `dartvex` for transport and auth
- `dartvex_codegen` for typed Dart bindings
- `dartvex_flutter` for runtime-aware Flutter widgets
- `dartvex_local` for local-first cache, offline queueing, and replay
- `dartvex_auth_better` for optional Better Auth (self-hosted) authentication
- `dartvex_auth2_convex` for optional Convex Auth v2 (`@convex-dev/auth`)
  authentication

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
open build/macos/Build/Products/Release/dartvex_flutter_demo.app

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
- an `Auth` tab with a **Demo / Better Auth / Convex Auth mode selector**:
  - **Demo mode**: deterministic `DemoAuthProvider` with login, cache restore,
    logout, forced reconnect, and provider diagnostics
  - **Better Auth mode**: self-hosted authentication running inside your Convex
    backend via `ConvexBetterAuthProvider` from `dartvex_auth_better`
    (requires `@convex-dev/better-auth` component; shows setup checklist if not configured)
  - **Convex Auth mode**: username/password sign-up and sign-in with
    `@convex-dev/auth` v2 via `ConvexAuthSessionProvider` from
    `dartvex_auth2_convex`, with a live view of the rotating session
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

The `Auth` tab includes a segmented button to switch between three auth modes.
All of them drive the same `ConvexClientWithAuth` wrapper — only the
provider implementation differs.

### Demo mode (default)

Uses `DemoAuthProvider`, a deterministic in-memory provider with no external
service. Public screens, Better Auth and Convex Auth work without this
provider, but Demo mode requires a JWT generated locally from the example backend key material.
The backend example requires Node.js 22.9 or newer and uses npm with the
committed `package-lock.json` (run `npm install` in `../convex-backend`
first).

1. Configure the demo JWT provider in Convex:

```bash
cd ../convex-backend
npm run demo:key
```

2. Run the printed `npx convex env set DEMO_JWKS ...` command. This publishes
   only the public JWKS to Convex. The private key remains in gitignored `.env`.

3. Run Flutter with a freshly generated token (capture it in a shell variable —
   see [Troubleshooting](#troubleshooting)). The token expires after 24 hours
   and is compiled into the app, so use it for local runs only:

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
4. Tap `Reconnect`.
5. Confirm the connection chip cycles through reconnecting and back while the
   session stays authenticated. The client replays its cached token on the new
   socket, so the auth diagnostics show no new `login()` or
   `loginFromCache()` call.
6. To see a token re-fetch, open the `Sync` tab and tap
   `Force a token refresh`: the server rejects a deliberately expired token
   and the client fetches a fresh one from the provider.
7. Back on `Auth`, tap `Logout`, then `Restore Session`.
8. Confirm the cached session restores without a visible login UI (one
   `loginFromCache()` call).

### Better Auth mode

Uses `ConvexBetterAuthProvider` from the `dartvex_auth_better` package with
a self-hosted auth backend running inside Convex. No external auth service
needed — credentials are stored in the Convex database.

#### Setup

1. Install the Better Auth component in the Convex backend:

   The backend example requires Node.js 22.9 or newer and uses npm with the
   committed `package-lock.json`, which already pins `better-auth` 1.7.17 and
   `@convex-dev/better-auth` ^0.13.0:

   ```bash
   cd example/convex-backend
   npm install
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

   A new deployment also needs `DEMO_JWKS` before it accepts the backend,
   even for this mode: see steps 1 and 2 of [Demo mode](#demo-mode-default).

5. Run the demo (no extra `--dart-define` needed beyond `CONVEX_DEMO_URL`):

   ```bash
   flutter run \
     --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud
   ```

If the Convex backend does not have the Better Auth component installed, the
app shows a setup checklist with the steps above.

### Convex Auth mode

Uses `ConvexAuthSessionProvider` from the `dartvex_auth2_convex` package with
[Convex Auth](https://docs.convex.dev/auth/convex-auth) v2 running inside the
Convex backend as components. Accounts are a username and a password; there
is no email to verify.

#### Setup

Convex Auth itself needs nothing beyond the backend: the committed
`package-lock.json` pins `@convex-dev/auth` 2.0.0, and access tokens are
signed by the deployment, so there is no secret to set for it.

The backend as a whole needs one variable before a new deployment accepts
it: `DEMO_JWKS`, the public key set of the Demo mode, which
`convex/auth.config.ts` reads.

```bash
cd example/convex-backend
npm install
npm run demo:key   # prints an `npx convex env set DEMO_JWKS ...` command
npx convex dev     # new deployment: configures it, then stops on DEMO_JWKS
# run the printed `npx convex env set DEMO_JWKS ...` command, then:
npx convex dev     # or npx convex deploy

cd ../flutter_app
flutter run \
  --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud
```

Without a deployment URL, the app shows a setup checklist with these steps.

#### What it shows

- **Sign up / sign in**: the panel sets `provider.signIn` to a
  `ConvexAuthSignIn` and calls `authClient.login()`. A rejected request is a
  `ConvexAuthSignInException`, whose `code` (`INVALID_CREDENTIALS`,
  `USERNAME_TAKEN`, `PASSWORD_TOO_SHORT`, …) the demo maps to a message in
  `describeConvexAuthError`.
- **A rotating session**: the access token lives one minute. The client
  refreshes the session before it expires, and every refresh replaces both
  the access token and the refresh token. The panel counts these rotations.
- **Persistence**: the provider hands every new session to
  `onSessionChanged`. The demo saves it in `ConvexAuthSessionStore`, an
  in-memory stand-in for the secure storage a real app would use, and passes
  it back as `initialSession` to the next client.
- **The backend's view**: `users:viewer` resolves the session to its user
  with `getAuthUserId`. The private feed on the `Chats` tab follows the user,
  not the session, so it survives a sign-out and a new sign-in.

The backend's functions are in `convex/convexAuth.ts` (Better Auth owns
`convex/auth.ts`), so the demo passes their paths to the adapter instead of
relying on the default `auth:<name>`: see `ConvexAuthDemoFunctions` in
`lib/src/features/auth/data/convex_auth_demo.dart`.

Suggested manual flow:

1. Open `Auth` and select `Convex Auth`.
2. Enter a username and a password of at least 10 characters, then tap
   `Sign Up`.
3. Confirm the header chip turns to `Convex Auth: signed in`, the session
   card shows a `userId` and a `sessionId`, and the backend line resolves the
   session to the same user. `Token rotations` reads 1 almost at once: like
   the official client, Dartvex fetches a fresh token as soon as the server
   has confirmed the first one.
4. Wait a minute: `Token rotations` goes up while the session stays
   authenticated, with the same `sessionId`.
5. Open `Chats` and send a private message.
6. Back on `Auth`, select `Demo`, then `Convex Auth` again. Switching modes
   rebuilds the Convex client: the session is restored from the store, as an
   app restores it at startup, without asking for the password.
7. Tap `Sign Out`. The session is revoked on the server and removed from the
   store.
8. Tap `Already have an account? Sign in`, try a wrong password (the panel
   shows `Wrong username or password.`), then the right one. The session card
   shows a new `sessionId` for the same `userId`, and the private message is
   still in `Chats`.

The session is kept in memory only: restarting the app signs you out. A real
app writes `session.toJson()` to secure storage in `onSessionChanged`; see
the `dartvex_auth2_convex` README.

#### `--dart-define` reference

| Key | Required | Description |
|-----|----------|-------------|
| `CONVEX_DEMO_URL` | Yes | Convex deployment URL |
| `CONVEX_DEMO_AUTH_TOKEN` | Demo mode only | JWT generated by `example/convex-backend`; not needed for public screens, Better Auth or Convex Auth |

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
- **Demo login stops working after a day** — the demo JWT expired (24 hours
  by default). Generate a new one and launch again; `DEMO_TOKEN_TTL_SECONDS`
  sets another lifetime for `npm run token`.
- **Auth tab shows "Demo token missing"** — `CONVEX_DEMO_AUTH_TOKEN` did not reach
  the build (usually the issue above). Public tabs, Better Auth and Convex Auth do
  not need it.
- **`./generate_bindings.sh: permission denied`** — run it via
  `bash example/generate_bindings.sh`, which works regardless of the file's
  executable bit.

## Regenerate the typed API

From the repo root:

```bash
bash example/generate_bindings.sh
```
