# dartvex_auth_convex

[Convex Auth](https://docs.convex.dev/auth/convex-auth) (`@convex-dev/auth`
v2) adapter for [Dartvex](https://github.com/AndreFrelicot/dartvex). It signs
in with Convex Auth methods and keeps the rotating session in sync with the
Convex client.

## How it works

Convex Auth v2 runs inside your deployment as Convex components:

- **Sign-in functions** are mutations of your app that return
  `{status: "complete", tokens}` or `{status: "error", userError}`.
- **Access tokens** are JWTs signed by the deployment, valid for one minute
  by default.
- **`refreshSession`** trades the refresh token for a new session. The
  refresh token rotates on every refresh.
- **`signOut`** revokes the session.

`ConvexAuthSessionProvider` implements Dartvex's `AuthProvider`, so
`ConvexClientWithAuth` sends the access token, refreshes it before it
expires, and asks the provider for a new one when the server rejects it.

Refreshes and sign-outs go over HTTP (`POST /api/mutation`), not the
WebSocket. The socket is paused while the client waits for a token, so a
refresh sent over it could never complete. The official client works the
same way. Concurrent refreshes of a session share one request, so a rotated
refresh token is never sent twice: the server treats a replayed refresh
token as a leak.

## Backend

Re-export the core and method functions from `convex/auth.ts`. The package
assumes the default `auth:<name>` paths:

```ts
const auth = setupConvexAuth({ component: components.auth });
export const { signOut, refreshSession, isAuthenticated } = auth;

export const { signUpWithUsernamePassword, signInWithUsernamePassword } =
  setupUsernamePassword(auth, { /* ... */ }).attachUserCallbacks({ /* ... */ });
```

## Usage

```dart
final authClient = ConvexAuthHttpClient(
  deploymentUrl: 'https://your-deployment.convex.cloud',
);
final provider = ConvexAuthSessionProvider(
  client: authClient,
  initialSession: await loadSession(), // null on first start
  onSessionChanged: saveSession,       // called on every rotation
);
final authed = ConvexClient('https://your-deployment.convex.cloud')
    .withAuth(provider, disposeClient: true);

// Restore the persisted session...
try {
  await authed.loginFromCache();
} on ConvexAuthSessionEndedException {
  // ...or sign in.
  provider.signIn = ConvexAuthSignIn.usernamePassword(
    username: 'alice',
    password: 'secret',
  );
  await authed.login();
}

// Later:
await authed.logout();
```

### Persisting the session

`ConvexAuthSession.toJson()` and `ConvexAuthSession.fromJson()` read and
write the token bundle. Store it in secure storage, for example
`flutter_secure_storage`, from `onSessionChanged`. Delete it when the
callback receives `null`. A session saved before a rotation stops working,
so save on every call.

### Sign-in methods

`ConvexAuthSignIn` has named constructors for the built-in methods:

| Constructor | Function |
|---|---|
| `usernamePassword` | `auth:signInWithUsernamePassword` |
| `usernamePasswordSignUp` | `auth:signUpWithUsernamePassword` |
| `emailPassword` | `auth:signInWithEmailPassword` |
| `completeEmailPasswordSignUp` | `auth:completeSignUpWithEmailPassword` |
| `completePasswordRecovery` | `auth:completePasswordRecovery` |
| `anonymous` | `auth:signInAnonymously` |

Pass `function:` when your functions live elsewhere. Use
`ConvexAuthSignIn(path, args)` for any other mutation that returns the
sign-in envelope.

Some steps return no session, such as `signUpWithEmailPassword` (it returns
a `browserSecret`) and `startPasswordRecovery`. Call them with
`authClient.mutation(...)`, then finish with the matching
`complete...` sign-in:

```dart
final start = await authClient.mutation(
  'auth:signUpWithEmailPassword',
  {'email': email, 'password': password},
) as Map;
if (start['success'] == true) {
  // Keep start['browserSecret'] until the user opens the email link.
  provider.signIn = ConvexAuthSignIn.completeEmailPasswordSignUp(
    emailCode: codeFromLink,
    browserSecret: start['browserSecret'] as String,
  );
  await authed.login();
}
```

Functions that need the signed-in user, such as `changePassword`, go
through the authenticated Convex client: `authed.mutation(...)`.

### Sessions obtained elsewhere

For OAuth or passkey flows you complete yourself, for example through a deep
link, pass the resulting token bundle to `provider.adoptSession(...)`, then
call `authed.login()`.

## Errors

| Exception | Meaning |
|---|---|
| `ConvexAuthSignInException` | The sign-in function rejected the request. `code` is the method's error, for example `INVALID_CREDENTIALS`, `USER_NOT_FOUND`, `USERNAME_TAKEN` or `RATE_LIMITED` (see `retryAfter`). |
| `ConvexAuthSessionEndedException` | There is no session, or the server reports it gone (expired, revoked, refresh token replayed). Sign in again. |
| `ConvexAuthException` | Any other failure. The current session is kept. When `retryable` is `true` (network errors, timeouts, HTTP 5xx and 429), retry later. |

## Not supported yet

- **Passkeys and OAuth redirects:** these flows need platform code. Use
  `adoptSession` with a bundle you obtained yourself.
- **SSR mode:** in this mode the refresh token lives in an httpOnly cookie,
  which does not apply to native clients.
