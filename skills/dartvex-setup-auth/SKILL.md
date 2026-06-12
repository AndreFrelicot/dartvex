---
name: dartvex-setup-auth
description: Add authentication to a Dart/Flutter app on Convex - Better Auth email/password and magic links via dartvex_auth_better, session persistence across restarts, or manual JWT auth for any OIDC provider. Use when the user wants login/signup, session restore, Better Auth, or to authenticate the dartvex Convex client.
license: MIT
metadata:
  author: AndreFrelicot
  ecosystem-version: "0.2.0"
---

# Authenticate a Dartvex App

Two paths:

- **A. Better Auth** (self-hosted, email/password, magic links) via
  `dartvex_auth_better` — full flow below.
- **B. Any other OIDC provider** (Auth0, Firebase Auth, Clerk, …) — your
  code obtains the JWT; hand it to dartvex (see "Manual JWT auth" at the
  end).

## A. Better Auth

### Dependencies

```yaml
dependencies:
  dartvex: ^0.2.0
  dartvex_auth_better: ^0.2.0
```

### Backend prerequisite — bearer() plugin

The Convex Better Auth configuration **must include the `bearer()` plugin**,
or session tokens cannot be restored across app restarts:

```typescript
// convex/authSetup.ts
import { bearer } from "better-auth/plugins";

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
(`npx skills add get-convex/agent-skills`) and
https://convex-better-auth.netlify.app.

For **Flutter web**, Better Auth must also expose the session-token header
through CORS: `Access-Control-Expose-Headers: set-auth-token` (browsers
never expose `Set-Cookie` to Dart; the cookie fallback is native-only).

### Sign in and connect

```dart
import 'package:dartvex/dartvex.dart';
import 'package:dartvex_auth_better/dartvex_auth_better.dart';

final authClient = BetterAuthClient(baseUrl: deploymentUrl);

final convexClient = ConvexClient(deploymentUrl);
final provider = ConvexBetterAuthProvider(client: authClient);
provider.email = email;
provider.password = password;

final authedClient = convexClient.withAuth(provider);
final session = await authedClient.login();
// session.token        — Convex JWT (WebSocket auth; refreshed automatically)
// session.sessionToken — Better Auth token (persist this one)
```

Sign-up: `provider.signUp(name: ..., email: ..., password: ...)` or
`authClient.signUp(...)`.

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
  final session = await authedClient.loginFromCache();
  // Restored: fresh Convex JWT, automatic refresh active.
}
```

### Sign out

```dart
await authClient.signOut(sessionToken: session.sessionToken);
await secureStorage.delete(key: 'session_token');
```

### Password reset and magic links

```dart
await authClient.forgotPassword(email: email, redirectTo: 'myapp://reset');
await authClient.resetPassword(token: resetToken, newPassword: newPassword);
await authClient.sendMagicLink(email: email, callbackURL: 'myapp://auth');
final session = await authClient.verifyMagicLink(token: magicLinkToken);
```

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
reports `true` — show an "authenticating…" indicator instead of a disconnect.

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

The backend must trust the issuer (`auth.config.ts` providers) — backend
side belongs to the Convex skills.

## Common mistakes

- Persisting the Convex JWT instead of `sessionToken` — the JWT expires in
  minutes; restore breaks.
- Missing `bearer()` plugin — login works but `loginFromCache()` cannot
  restore sessions.
- Hardcoding the deployment/auth URL — inject at run time.
- Treating a transient 5xx from the auth server as "signed out" —
  `dartvex_auth_better` already distinguishes expired sessions (401/403)
  from server failures; do not collapse them in app code either.
