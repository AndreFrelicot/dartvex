---
name: dartvex-setup-auth
description: Add authentication to a Dart/Flutter app on Convex - Better Auth email/password and magic links via dartvex_auth_better, session persistence across restarts, deployment-issued JWTs (ctx.auth.signJwt), or manual JWT auth for any OIDC provider. Use when the user wants login/signup, session restore, sign-out, Better Auth, or to authenticate the dartvex Convex client.
license: MIT
metadata:
  author: AndreFrelicot
  ecosystem-version: "0.3.0"
---

# Authenticate a Dartvex App

Three paths:

- **A. Better Auth** (self-hosted, email/password, magic links) via
  `dartvex_auth_better` — full flow below.
- **B. Any other OIDC provider** (Auth0, Firebase Auth, Clerk, …) — your
  code obtains the JWT; hand it to dartvex ("Manual JWT auth").
- **C. Deployment-issued JWTs** — a Convex mutation verifies your own
  credential and mints a short-lived token with `ctx.auth.signJwt`; no
  external identity provider.

Whatever the path, sign in, restore and sign out through one wrapper
(`ConvexClientWithAuth`, or `setAuthWithRefresh` for B/C) so the Convex
client's auth state never diverges from the provider's.

## A. Better Auth

### Dependencies

```yaml
dependencies:
  dartvex: ^0.3.0
  dartvex_auth_better: ^0.3.0
```

The example backend pins `better-auth` 1.7.17, `@convex-dev/better-auth`
^0.13.0 and `convex` ^1.49.0, which need Node.js 22 or newer. Pair
`@convex-dev/better-auth` 0.12.7+ with `dartvex_auth_better` 0.3.0 or newer
(older releases misread the expired `convex_jwt` cookie those versions send).

### Backend prerequisite — bearer() plugin

The Convex Better Auth configuration **must include the `bearer()` plugin**,
or session tokens cannot be restored across app restarts:

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
    ],
  });
};
```

Backend authoring beyond this snippet → official Convex skills
(`npx skills add convex/agent-skills`) and
https://convex-better-auth.netlify.app.

For **Flutter web**, Better Auth must also expose the session-token header
through CORS: `Access-Control-Expose-Headers: set-auth-token` (browsers
never expose `Set-Cookie` to Dart; the cookie fallback is native-only), and
the web origin must be in Better Auth's `trustedOrigins`.

### Create the auth client — which URL?

Better Auth runs on the deployment's **HTTP-actions origin**
(`CONVEX_SITE_URL`), not the sync URL. For `https://<name>.convex.cloud` the
client derives `https://<name>.convex.site` itself. Anywhere else, pass
`siteUrl`:

```dart
import 'package:dartvex/dartvex.dart';
import 'package:dartvex_auth_better/dartvex_auth_better.dart';

// Convex cloud: the site URL is derived.
final authClient = BetterAuthClient(baseUrl: deploymentUrl);

// Local backend (`npx convex dev --local`), self-hosted, or custom domain:
final localAuthClient = BetterAuthClient(
  baseUrl: 'http://127.0.0.1:3210',
  siteUrl: 'http://127.0.0.1:3211', // the HTTP-actions port / CONVEX_SITE_URL
);
```

Other options: `basePath` (when Better Auth is mounted somewhere other than
`/api/auth`) and `requestTimeout` (default 30 s, `null` disables it).

### Sign in and connect

```dart
final convexClient = ConvexClient(deploymentUrl);
final provider = ConvexBetterAuthProvider(client: authClient);
final authedClient = convexClient.withAuth(provider);

provider.email = email;
provider.password = password;
final session = await authedClient.login();
// session.sessionToken — Better Auth token (persist this one)
// session.token        — the Convex JWT at login time (a snapshot)
```

The wrapper refreshes the Convex JWT by itself before it expires, but
`session.token` (and `AuthAuthenticated.userInfo.token`) keep the login-time
value. When you need the JWT currently in use — for example
`Authorization: Bearer ...` on a Convex HTTP action — read
`authedClient.currentAuthToken`.

Do not also call `authClient.signIn(...)`: the raw `BetterAuthClient`
session APIs (`signIn`, `signUp`, `getSession`, `signOut`) are only for
sessions never attached to a Convex client, and mixing them with
`authedClient.login()` creates two server sessions.

### Sign up

```dart
try {
  await provider.signUp(name: name, email: email, password: password);
  // signUp() does not authenticate the Convex client; login() reuses the
  // session it just created instead of signing in again.
  final session = await authedClient.login();
} on BetterAuthEmailVerificationRequiredException {
  // Server requires email verification: the account exists, no session yet.
}
```

### Persist the session across restarts

Store `session.sessionToken` in secure storage (e.g.
`flutter_secure_storage`) — never the Convex JWT, which is short-lived:

```dart
// After login:
await secureStorage.write(key: 'session_token', value: session.sessionToken);

// On app restart:
final stored = await secureStorage.read(key: 'session_token');
final provider = ConvexBetterAuthProvider(
  client: authClient,
  initialSessionToken: stored, // seeds the cache for loginFromCache()
);
final authedClient = convexClient.withAuth(provider);
if (stored != null) {
  try {
    await authedClient.loginFromCache();
    // Restored: fresh Convex JWT, automatic refresh active.
  } on StateError {
    // Session expired or revoked (Better Auth get-session) — sign in again.
    await secureStorage.delete(key: 'session_token');
  } on BetterAuthSessionExpiredException {
    // The Convex token endpoint rejected the session.
    await secureStorage.delete(key: 'session_token');
  } on BetterAuthException catch (e) {
    // e.retryable: offline, timeout, 5xx/429 — keep the token, retry later.
  }
}
```

To avoid queries running unauthenticated while the restore is in flight,
create the client with `ConvexClientConfig(expectAuth: true)`: nothing is
sent until the first `login`/`loginFromCache` (or `clearAuth()` when there is
no stored session) decides the auth state.

### Sign out

```dart
await authedClient.logout();
await secureStorage.delete(key: 'session_token');
```

`authedClient.logout()` revokes the provider's Better Auth session, clears
the provider's cached session **and its email/password** (set them again
before the next `login()`), and clears the Convex client's auth. Never sign
out with `authClient.signOut(...)` for a session the wrapper uses: the
Convex client would stay authenticated until its JWT expires.

If the app also uses `dartvex_local`, call `localClient.reset()` on sign-out
or user switch so the next user neither sees cached results nor replays
queued mutations of the previous one.

### Password reset

```dart
await authClient.forgotPassword(email: email, redirectTo: 'myapp://reset');
// Better Auth redirects to `redirectTo?token=...`; read it from the deep link.
await authClient.resetPassword(token: resetToken, newPassword: newPassword);
```

### Magic links

Better Auth's default email opens the link in a browser, which consumes the
single-use token there. For a native app, make the server's
`magicLink({ sendMagicLink })` email a deep link carrying the token
(`myapp://auth/magic-link?token=${token}`), then hand the session to the
provider so the Convex client gets the JWT and its refresh:

```dart
await authClient.sendMagicLink(email: email);

// When the deep link opens the app:
final session = await authClient.verifyMagicLink(token: magicLinkToken);
provider.adoptSession(session);
await authedClient.loginFromCache();
await secureStorage.write(key: 'session_token', value: session.sessionToken);
```

Do not shortcut with `convexClient.setAuth(session.token)`: it skips the
refresh. Custom schemes used for `redirectTo`/`callbackURL` must be listed in
the server's `trustedOrigins`. A bad or reused token throws a
`BetterAuthException` with `code` `INVALID_TOKEN`, `EXPIRED_TOKEN` or
`ATTEMPTS_EXCEEDED`.

### Errors

Every adapter error is a `BetterAuthException` (a `ConvexException`):

- `code` — Better Auth's error code (`INVALID_EMAIL_OR_PASSWORD`,
  `USER_ALREADY_EXISTS`, ...); `data` holds the decoded error body.
- `retryable` — `true` for 5xx/429, network errors and timeouts.
- `BetterAuthSessionExpiredException` — the Convex token endpoint rejected
  the session (delete the stored token).
- `BetterAuthEmailVerificationRequiredException` — sign-up created the
  account without a session; exposes `user`.
- `BetterAuthTwoFactorRequiredException` — sign-in needs a second factor;
  exposes `twoFactorMethods` (the verification endpoints are not wrapped).

`loginFromCache()` reports an expired session as
`StateError('Better Auth session expired.')`, not as an exception subclass.

### React to auth state (Flutter)

```dart
ConvexAuthProvider<BetterAuthSession>(
  client: authedClient,
  child: ConvexAuthBuilder<BetterAuthSession>(
    builder: (context, state) => switch (state) {
      AuthLoading<BetterAuthSession>() => const CircularProgressIndicator(),
      AuthAuthenticated<BetterAuthSession>(:final userInfo) =>
          HomeScreen(user: userInfo),
      AuthUnauthenticated<BetterAuthSession>() => const LoginScreen(),
    },
  ),
)
```

While a rejected token is being recovered, `ConvexAuthRefreshingBuilder`
reports `true` — show an "authenticating…" indicator instead of a
disconnect.

## B. Manual JWT auth (any OIDC provider)

```dart
// Static token (testing):
await client.setAuth(jwt);

// Production — dartvex schedules proactive refresh from the token's
// exp/iat claims and re-fetches on server rejection:
final handle = await client.setAuthWithRefresh(
  fetchToken: ({required bool forceRefresh}) async {
    return obtainJwtFromYourProvider(forceRefresh: forceRefresh);
  },
  onAuthChange: (isAuthenticated) => print(isAuthenticated),
);
// Later: await handle.cancel(); or await client.clearAuth();
```

`onAuthChange(true)` fires once per flow, when the server first confirms
the token, not on every refresh. `client.isAuthenticated` and
`client.currentAuthToken` give the current state and token. Server-side, the
issuer must be trusted in `auth.config.ts`.

To wrap such a provider in the same `login`/`loginFromCache`/`logout` API as
Better Auth, implement `AuthProvider<T>` and use `client.withAuth(provider)`:
`loginFromCache` is the refresh hook and must return a freshly issued token.
When the session no longer exists, throw an error implementing
`AuthSessionEndedError` (for example
`class SessionGone extends StateError implements AuthSessionEndedError`):
a failed re-login or restore then signs out instead of keeping the previous
session as authenticated. Any other error is treated as transient.

## C. Deployment-issued JWTs (`ctx.auth.signJwt`)

In recent Convex releases (present in convex 1.49, absent in 1.41) a
mutation can sign an ES256 JWT with the deployment's own key (`iss` = `CONVEX_CLOUD_URL`, lifetime at most 1 hour). The app sends
a credential it already has (device secret, invite code, your own session
token), the mutation verifies it and returns a token; dartvex's refresh flow
handles the rest.

```typescript
// convex/auth.config.ts
export default {
  providers: [
    {
      type: "customJwt",
      issuer: process.env.CONVEX_CLOUD_URL!,
      jwks: `${process.env.CONVEX_CLOUD_URL}/.well-known/jwks.json`,
      algorithm: "ES256",
      applicationID: "my-dart-app",
    },
  ],
};

// convex/session.ts
export const issueToken = mutation({
  args: { credential: v.string() },
  returns: v.string(),
  handler: async (ctx, { credential }) => {
    const userId = await verifyCredential(ctx, credential); // your check
    return await ctx.auth.signJwt({
      claims: { sub: userId, aud: "my-dart-app" },
      expiresInSeconds: 15 * 60,
    });
  },
});
```

```dart
// Mint tokens on a separate, unauthenticated client: the authenticated
// client pauses its socket while it refreshes a rejected token.
final tokenClient = ConvexClient(deploymentUrl);
final client = ConvexClient(
  deploymentUrl,
  config: const ConvexClientConfig(expectAuth: true),
);
await client.setAuthWithRefresh(
  fetchToken: ({required bool forceRefresh}) async =>
      await tokenClient.mutate('session:issueToken', {
        'credential': credential,
      }) as String,
);
```

Tokens cannot be revoked individually — keep lifetimes short and make
`issueToken` refuse revoked credentials.

## Common mistakes

- Signing out with `authClient.signOut(...)` instead of
  `authedClient.logout()` — the Convex client stays signed in.
- Persisting the Convex JWT instead of `sessionToken` — the JWT expires in
  minutes; restore breaks.
- Missing `bearer()` plugin — login works but `loginFromCache()` cannot
  restore sessions.
- Passing the sync URL as the auth origin for local, self-hosted or
  custom-domain deployments — pass `siteUrl`.
- Using `session.token` for HTTP actions after a refresh — read
  `authedClient.currentAuthToken`.
- Hardcoding the deployment/auth URL — inject at run time.
- Treating a transient failure as "signed out" — only `StateError` /
  `BetterAuthSessionExpiredException` mean the session is gone (both
  implement `AuthSessionEndedError`); keep the token on `retryable` errors.
