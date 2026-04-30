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

## The Dartvex ecosystem

| Package | Description |
|---------|-------------|
| [`dartvex`](https://pub.dev/packages/dartvex) | Core client — WebSocket sync, subscriptions, auth |
| [`dartvex_flutter`](https://pub.dev/packages/dartvex_flutter) | Flutter widgets — Provider, Query, Mutation |
| [`dartvex_codegen`](https://pub.dev/packages/dartvex_codegen) | CLI code generator — type-safe Dart bindings from schema |
| [`dartvex_local`](https://pub.dev/packages/dartvex_local) | Offline support — SQLite cache, mutation queue |
| **[`dartvex_auth_better`](https://pub.dev/packages/dartvex_auth_better)** | Better Auth adapter |

Source and full docs: [github.com/AndreFrelicot/dartvex](https://github.com/AndreFrelicot/dartvex)

## Installation

```yaml
dependencies:
  dartvex: ^0.1.4
  dartvex_auth_better: ^0.1.3
```

## Server-Side Setup

Your Convex Better Auth configuration **must include the `bearer()` plugin** for mobile/desktop session persistence:

```typescript
// convex/authSetup.ts
import { bearer } from "better-auth/plugins";

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

## Usage

### 1. Create the auth client

```dart
import 'package:dartvex_auth_better/dartvex_auth_better.dart';

final authClient = BetterAuthClient(
  baseUrl: 'https://your-deployment.convex.cloud',
);
```

### 2. Sign up / sign in

```dart
final session = await authClient.signIn(
  email: 'user@example.com',
  password: 'securePassword',
);

// session.token         — Convex JWT (for WebSocket auth)
// session.sessionToken  — Better Auth token (for session persistence)
```

### 3. Connect to Convex

```dart
import 'package:dartvex/dartvex.dart';

final convexClient = ConvexClient('https://your-deployment.convex.cloud');
final provider = ConvexBetterAuthProvider(client: authClient);
provider.email = 'user@example.com';
provider.password = 'securePassword';

final authedClient = convexClient.withAuth(provider);
await authedClient.login();
```

### 4. Persist sessions (mobile/desktop)

Store `session.sessionToken` in secure storage after login. On app restart, use it to restore the session:

```dart
// After login — save the session token
final session = await authedClient.login();
await secureStorage.write(key: 'session_token', value: session.sessionToken);

// On app restart — restore from cache
final stored = await secureStorage.read(key: 'session_token');
if (stored != null) {
  final session = await authClient.getSession(sessionToken: stored);
  if (session != null) {
    // Session restored — session.token has a fresh Convex JWT
  }
}
```

### 5. Sign out

```dart
await authClient.signOut(sessionToken: session.sessionToken);
await secureStorage.delete(key: 'session_token');
```

### 6. Password recovery and magic links

```dart
await authClient.forgotPassword(
  email: 'user@example.com',
  redirectTo: 'myapp://reset-password',
);

await authClient.resetPassword(
  token: resetToken,
  newPassword: 'newSecurePassword',
);

await authClient.sendMagicLink(
  email: 'user@example.com',
  callbackURL: 'myapp://auth-callback',
);

final session = await authClient.verifyMagicLink(token: magicLinkToken);
```

## API Overview

### BetterAuthClient

- `signUp({email, password, name?})` — create account, returns `BetterAuthSession`
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

- `login()` — sign in with stored email/password
- `loginFromCache()` — restore session from cached token
- `logout()` — sign out and clear cache
- `signUp({email, password, name?})` — create account and authenticate

### BetterAuthSession

```dart
class BetterAuthSession {
  final String token;         // JWT for Convex WebSocket auth
  final String sessionToken;  // Better Auth token (for persistence & sign-out)
  final String userId;        // Better Auth user ID
  final String email;         // User email
  final String? name;         // Optional display name
}
```

## Full Documentation

See the [Dartvex monorepo](https://github.com/AndreFrelicot/dartvex) for full documentation and examples.
