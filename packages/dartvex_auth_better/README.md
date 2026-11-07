<p align="center">
  <a href="https://github.com/AndreFrelicot/dartvex">
    <img src="https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-logo-512.png" width="128" alt="Dartvex" />
  </a>
</p>

# dartvex_auth_better

Better Auth adapter for [dartvex](https://pub.dev/packages/dartvex) — the pure Dart client for [Convex](https://convex.dev). Self-hosted authentication powered by [Better Auth](https://www.better-auth.com/).

This keeps Better Auth isolated from the core SDK packages:

- [`dartvex`](https://pub.dev/packages/dartvex) stays provider-agnostic
- [`dartvex_flutter`](https://pub.dev/packages/dartvex_flutter) stays provider-agnostic
- Better Auth logic lives here

<p align="center">
  <a href="https://github.com/AndreFrelicot/dartvex">
    <img src="https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-poster.webp" width="900" alt="Dartvex Flutter demo — real-time chats running on iOS and macOS" />
  </a>
</p>

## The Dartvex ecosystem

| Package | Description |
|---------|-------------|
| [`dartvex`](https://pub.dev/packages/dartvex) | Core client — WebSocket sync, subscriptions, auth |
| [`dartvex_flutter`](https://pub.dev/packages/dartvex_flutter) | Flutter widgets — Provider, Query, Mutation |
| [`dartvex_codegen`](https://pub.dev/packages/dartvex_codegen) | CLI code generator — type-safe Dart bindings from function validators |
| [`dartvex_local`](https://pub.dev/packages/dartvex_local) | Offline support — SQLite cache, mutation queue |
| **[`dartvex_auth_better`](https://pub.dev/packages/dartvex_auth_better)** | Better Auth adapter |

Source and full docs: [github.com/AndreFrelicot/dartvex](https://github.com/AndreFrelicot/dartvex)

## Installation

```yaml
dependencies:
  dartvex: ^0.3.0
  dartvex_auth_better: ^0.3.0
```

## Supported versions

The example backend in
[`example/convex-backend`](https://github.com/AndreFrelicot/dartvex/tree/main/example/convex-backend)
pins `better-auth` 1.7.17, `@convex-dev/better-auth` ^0.13.0 and `convex`
^1.49.0 (Node.js 22 or newer); the client is unit-tested against the
response shapes of those versions. The endpoints and response shapes it uses
are unchanged since `better-auth` 1.6 / `@convex-dev/better-auth` 0.12.

`@convex-dev/better-auth` 0.12.7 and newer expire the `convex_jwt` cookie on
sign-in, sign-up and magic-link responses. Earlier releases of this package
read that emptied cookie as the Convex token, so upgrade this package
together with the server component.

## Server-Side Setup

Your Convex Better Auth configuration **must include the `bearer()` plugin** for mobile/desktop session persistence:

```typescript
// convex/auth.ts
import { betterAuth } from "better-auth";
import { bearer } from "better-auth/plugins";
import { convex } from "@convex-dev/better-auth/plugins";

export const createAuth = (ctx) => {
  return betterAuth({
    // ...
    plugins: [
      bearer(), // Required for mobile/API clients
      convex({ authConfig }),
      // ...
    ],
  });
};
```

Without `bearer()`, session tokens cannot be restored across app restarts.

### Flutter web CORS

For Flutter web, Better Auth must expose the session-token header through CORS:

```http
Access-Control-Expose-Headers: set-auth-token
```

Browsers do not expose `Set-Cookie` to Dart or JavaScript, so the cookie fallback
is native-only. Web sign-in and sign-up need either the exposed
`set-auth-token` header or a non-empty JSON `token` field in the Better Auth
response body. List the web app's origin in Better Auth's `trustedOrigins`.

## Usage

### 1. Create the auth client

```dart
import 'package:dartvex_auth_better/dartvex_auth_better.dart';

final authClient = BetterAuthClient(
  baseUrl: 'https://your-deployment.convex.cloud',
);
```

Better Auth is served from the deployment's HTTP-actions origin
(`CONVEX_SITE_URL`). For `*.convex.cloud` URLs the client derives it
(`*.convex.site`). Pass it explicitly with `siteUrl` when it cannot be
derived:

```dart
// Local backend (`npx convex dev`): HTTP actions run on their own port.
final localAuth = BetterAuthClient(
  baseUrl: 'http://127.0.0.1:3210',
  siteUrl: 'http://127.0.0.1:3211',
);

// Custom domain or self-hosted deployment.
final customAuth = BetterAuthClient(
  baseUrl: 'https://api.example.com',
  siteUrl: 'https://auth.example.com',
);
```

Shipped native apps cannot be updated as quickly as a deployment URL changes,
so prefer a custom domain or a runtime-configurable URL for production.

Other options:

- `basePath` — the path Better Auth is mounted on, when the server sets a
  custom Better Auth `basePath` (default `/api/auth`).
- `requestTimeout` — per-request timeout (default 30 seconds, `null`
  disables it).

### 2. Connect to Convex and sign in

Sign in, restore and sign out through the auth wrapper so the Convex client
and the provider stay in sync:

```dart
import 'package:dartvex/dartvex.dart';

final convexClient = ConvexClient('https://your-deployment.convex.cloud');
final provider = ConvexBetterAuthProvider(client: authClient);
final authedClient = convexClient.withAuth(provider);

provider.email = 'user@example.com';
provider.password = 'securePassword';
final session = await authedClient.login();

// session.sessionToken  — Better Auth token (for session persistence)
// session.token         — the Convex JWT at login time (a snapshot)
```

The wrapper keeps the Convex JWT fresh by calling the provider again before
it expires. `session.token` (like `AuthAuthenticated.userInfo.token`) is not
updated by those refreshes: read `authedClient.currentAuthToken` when you
need the JWT currently in use, for example for
`Authorization: Bearer ...` on a Convex HTTP action.

### 3. Sign up

```dart
try {
  await provider.signUp(
    name: 'Alice',
    email: 'alice@example.com',
    password: 'securePassword',
  );
  // signUp() does not authenticate the Convex client. login() reuses the
  // session signUp() just created instead of signing in again.
  final session = await authedClient.login();
} on BetterAuthEmailVerificationRequiredException {
  // The server requires email verification (or disables autoSignIn): the
  // account exists but has no session yet. Ask the user to verify, then
  // sign in.
}
```

### 4. Persist sessions (mobile/desktop)

Store `session.sessionToken` in secure storage after login. On app restart, use it to restore the session:

```dart
// After login — save the session token
final session = await authedClient.login();
await secureStorage.write(key: 'session_token', value: session.sessionToken);

// On app restart — seed the provider with the persisted token, then restore
final stored = await secureStorage.read(key: 'session_token');
final provider = ConvexBetterAuthProvider(
  client: authClient,
  initialSessionToken: stored,
);
final authedClient = convexClient.withAuth(provider);
if (stored != null) {
  try {
    final session = await authedClient.loginFromCache();
    // Session restored — session.token has a fresh Convex JWT, and the
    // Convex client is authenticated with automatic token refresh.
  } on StateError {
    // No cached session, or Better Auth reports it as expired/revoked.
    await secureStorage.delete(key: 'session_token');
    // Show the sign-in screen.
  } on BetterAuthSessionExpiredException {
    // The Convex token endpoint rejected the session.
    await secureStorage.delete(key: 'session_token');
  } on BetterAuthException catch (error) {
    // error.retryable: offline, timeout, 5xx/429 — keep the stored token and
    // retry later.
  }
}
```

`loginFromCache()` reports an expired or revoked session as a `StateError`
(`'Better Auth session expired.'`), not as a `BetterAuthException`; this is
deliberate and kept for compatibility.

For one-off validation outside the provider flow,
`authClient.getSession(sessionToken: stored)` also returns a fresh session (or
`null` when the session has expired).

### 5. Sign out

```dart
await authedClient.logout();
await secureStorage.delete(key: 'session_token');
```

`authedClient.logout()` revokes the provider's Better Auth session, clears the
provider's cached session and credentials, and clears the Convex client's
auth. Do not sign out with `authClient.signOut(...)` for a session the wrapper
uses: the Convex client would stay authenticated until its JWT expires.

### 6. Password recovery and magic links

```dart
await authClient.forgotPassword(
  email: 'user@example.com',
  redirectTo: 'myapp://reset-password',
);

// Better Auth redirects to `redirectTo?token=...`; read the token from the
// deep link.
await authClient.resetPassword(
  token: resetToken,
  newPassword: 'newSecurePassword',
);
```

Better Auth's default magic-link email opens the link in a browser, which
consumes the single-use token there and redirects to `callbackURL` without
it. For a native app, make the server email a deep link that carries the
token:

```typescript
// convex/auth.ts
import { magicLink } from "better-auth/plugins";

magicLink({
  sendMagicLink: async ({ email, token }) => {
    await sendEmail(email, `myapp://auth/magic-link?token=${token}`);
  },
}),
```

Then exchange the token from the deep link and hand the session to the
provider:

```dart
await authClient.sendMagicLink(email: 'user@example.com');

// When the deep link opens the app:
final session = await authClient.verifyMagicLink(token: magicLinkToken);
provider.adoptSession(session);
await authedClient.loginFromCache();
await secureStorage.write(key: 'session_token', value: session.sessionToken);
```

`adoptSession()` only stages the session: it becomes the provider's session
(and `provider.cachedSession`) once that `loginFromCache()` succeeds. If the
restore fails, the session that was signed in before stays current in both
the provider and the Convex client; after a transient failure, calling
`loginFromCache()` again retries the staged session. A `login()`, `logout()`
or another `adoptSession()` discards it.

Custom schemes used for `redirectTo` or `callbackURL` must be listed in the
server's `trustedOrigins`. An invalid, expired or reused magic-link token
throws a `BetterAuthException` whose `code` is `INVALID_TOKEN`,
`EXPIRED_TOKEN` or `ATTEMPTS_EXCEEDED`.

### Using BetterAuthClient directly

`authClient.signIn(...)`, `signUp(...)`, `getSession(...)` and `signOut(...)`
manage Better Auth sessions without a Convex client. Use them only for
sessions you never attach to `ConvexClientWithAuth`; combining
`authClient.signIn(...)` with `authedClient.login()` creates two separate
server sessions.

## Errors

All adapter errors are `BetterAuthException`s (a `ConvexException`):

- `code` — Better Auth's error code when the server sent one
  (`INVALID_EMAIL_OR_PASSWORD`, `EMAIL_NOT_VERIFIED`, `USER_ALREADY_EXISTS`,
  ...); `data` holds the decoded error body.
- `retryable` — `true` for 5xx and 429 responses, network errors
  (including TLS handshake failures), timeouts, and a Convex token response
  that is not JSON (typically a proxy or captive portal page).
- `BetterAuthSessionExpiredException` — the Convex token endpoint rejected
  an existing session with 401/403 (an `AuthSessionEndedError`). A 200
  token response without a token is a plain `BetterAuthException`, and so
  is a rejected token for a session that `signIn`, `signUp` or
  `verifyMagicLink` just created; that new session is signed out and the
  session the app already had is kept.
- `BetterAuthEmailVerificationRequiredException` — sign-up created the
  account without a session (`token: null`); exposes `user`.
- `BetterAuthTwoFactorRequiredException` — sign-in needs a second factor
  (`twoFactorRedirect`); exposes `twoFactorMethods`. The two-factor
  verification endpoints are not wrapped yet.

## API Overview

### BetterAuthClient

- `BetterAuthClient({baseUrl, siteUrl?, basePath?, httpClient?, requestTimeout?})`
- `signUp({name, email, password})` — create account, returns `BetterAuthSession`
- `signIn({email, password})` — authenticate, returns `BetterAuthSession`
- `forgotPassword({email, redirectTo?})` — send password reset email
- `resetPassword({token, newPassword})` — confirm password reset
- `sendMagicLink({email, callbackURL?})` — send passwordless sign-in link
- `verifyMagicLink({token})` — exchange magic link token for a session
- `signOut({sessionToken})` — end session
- `getSession({sessionToken})` — validate existing session and get fresh Convex JWT
- `close()` — dispose HTTP client

### ConvexBetterAuthProvider

Implements `AuthProvider<BetterAuthSession>` from `dartvex`:

- `ConvexBetterAuthProvider({client, initialSessionToken?})` — pass a
  persisted session token to restore the session across app restarts
- `login()` — sign in with stored email/password
- `loginFromCache()` — restore session from the cached (or seeded) token, or
  finish an `adoptSession()`. Through `authedClient.loginFromCache()` this
  is a new user intent: a `login()` still in flight is superseded (it throws
  and its new server session is signed out). The wrapper's background token
  refreshes also call it, but never supersede a pending `login()`.
- `logout()` — sign out and clear the cached session and credentials
- `signUp({name, email, password, onIdToken?})` — create an account and cache
  its session; call `authedClient.login()` afterwards to authenticate the
  Convex client (it reuses the sign-up session)
- `adoptSession(session)` — stage a session obtained elsewhere (for example
  from `verifyMagicLink`); follow with `authedClient.loginFromCache()`, which
  makes it current once restored

### BetterAuthSession

```dart
class BetterAuthSession {
  final String token;         // Convex JWT when the session was obtained
  final String sessionToken;  // Better Auth token (for persistence & sign-out)
  final String userId;        // Better Auth user ID
  final String email;         // User email
  final String? name;         // Optional display name
}
```

## Full Documentation

See the [Dartvex monorepo](https://github.com/AndreFrelicot/dartvex) for full documentation and examples.
