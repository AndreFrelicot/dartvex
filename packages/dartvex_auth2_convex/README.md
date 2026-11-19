# dartvex_auth2_convex

[Convex Auth](https://docs.convex.dev/auth/convex-auth) (`@convex-dev/auth`
v2) adapter for [Dartvex](https://github.com/AndreFrelicot/dartvex). It signs
in with Convex Auth methods and keeps the rotating session in sync with the
Convex client.

The `auth2` in the package name is the Convex Auth major version: this adapter
targets the v2 protocol.

A working example is the Convex Auth mode of the
[demo app](https://github.com/AndreFrelicot/dartvex/tree/main/example/flutter_app)
and its
[backend](https://github.com/AndreFrelicot/dartvex/tree/main/example/convex-backend).

## How it works

Convex Auth v2 runs inside your deployment as Convex components:

- **Sign-in functions** are mutations of your app that return
  `{status: "complete", tokens}` or `{status: "error", userError}`.
- **Access tokens** are JWTs signed by the deployment, valid for one minute
  by default.
- **`refreshSession`** trades the refresh token for a new session. The
  refresh token rotates on every refresh.
- **`signOut`** revokes the session, whichever of its refresh tokens is
  presented.

`ConvexAuthSessionProvider` implements Dartvex's `AuthProvider`, so
`ConvexClientWithAuth` sends the access token, refreshes it before it
expires, and asks the provider for a new one when the server rejects it.

Refreshes and sign-outs go over HTTP (`POST /api/mutation`), not the
WebSocket. The socket is paused while the client waits for a token, so a
refresh sent over it could never complete. The official client works the
same way. Concurrent refreshes of a session share one request.

The server keeps track of every refresh token of a session. The latest one,
and the one it was issued from, are accepted (so a refresh whose response was
lost can be retried). An older one is taken for a stolen token and ends the
session. This is why the stored session has to follow every rotation, in
order (see [Persisting the session](#persisting-the-session)).

## Backend

Accept the access tokens of Convex Auth in `convex/auth.config.ts`:

```ts
import type { AuthConfig } from "convex/server";
import { convexAuthProvider } from "@convex-dev/auth/server";

export default {
  providers: [convexAuthProvider()],
} satisfies AuthConfig;
```

Re-export the core and method functions from `convex/auth.ts`. The package
assumes the default `auth:<name>` paths:

```ts
const auth = setupConvexAuth({ component: components.auth });
export const { signOut, refreshSession, isAuthenticated } = auth;

export const { signUpWithUsernamePassword, signInWithUsernamePassword } =
  setupUsernamePassword(auth, { /* ... */ }).attachUserCallbacks({ /* ... */ });
```

In your functions, identify the caller with `getAuthUserId(ctx)`. A Convex
Auth access token names a session, not a user: `identity.subject` and
`identity.tokenIdentifier` change at every sign-in, so data keyed on them
would be lost to the user the next time they sign in.

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
`flutter_secure_storage`, from `onSessionChanged`, and delete it when the
callback receives `null`:

```dart
Future<void> saveSession(ConvexAuthSession? session) => session == null
    ? storage.delete(key: 'convex_auth_session')
    : storage.write(
        key: 'convex_auth_session',
        value: jsonEncode(session.toJson()),
      );
```

Return the future of the write, as above. The provider then:

- runs the saves one at a time, in the order of the changes, so an older
  write cannot land after a newer one or after the removal of a logout;
- hands a new session to the Convex client only once it has been saved;
- completes `logout()` only once the stored session has been removed.

A write that never completes therefore blocks sign-in, refresh and
sign-out: bound it with a timeout. An error thrown by the callback does not
interrupt the auth flow; it goes to `onBackgroundError` (or to the current
zone when that is not set). The stored session is then out of date, and the
next start may restore a refresh token the server no longer accepts. The
provider writes the session again at its next change.

`logout()` is the exception: when the session was signed out but could not
be removed from your storage, it throws the error of the callback, because a
restart would restore that session. Call `logout()` again to retry the
removal; nothing is sent to the server the second time.

`await provider.sessionSaved` completes when every save queued so far is
done, for example before the app exits.

**One provider per stored session.** Two providers that share the same
storage (two browser tabs, two isolates) are not coordinated: each rotates
the refresh token on its own, and the one left with a token two rotations
old makes the server end the session. On the web, this package does not
support several tabs sharing one stored session yet.

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

`@convex-dev/auth` 2.0.0 does not export its anonymous method publicly, so
`anonymous` only works when your app defines a mutation at that path that
returns the sign-in envelope.

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

The provider owns the sessions it is given and ends the ones nobody uses
any more: a session replaced by another one at `login()`, and a staged
session that another `adoptSession` or a `logout()` discards. It tells two
sessions apart by `ConvexAuthSession.sessionId` (the `sub` claim of the
access token), and never revokes a bundle of the session in use: adopting a
later rotation of the current session keeps it alive. A failed background
revocation is reported to `onBackgroundError`.

## Errors

| Exception | Meaning |
|---|---|
| `ConvexAuthSignInException` | The sign-in function rejected the request. `code` is the method's error, for example `INVALID_CREDENTIALS`, `USER_NOT_FOUND`, `USERNAME_TAKEN` or `RATE_LIMITED` (see `retryAfter`). |
| `ConvexAuthSessionEndedException` | There is no session, or the server reports it gone (expired, revoked, or ended after an outdated refresh token was presented). Sign in again. |
| `ConvexAuthException` | Any other failure. The current session is kept. When `retryable` is `true` (network errors, timeouts, HTTP 5xx and 429), retry later. |

`message` and `toString()` only say what failed (the function, the HTTP
status, an error code), so they can be logged. What the server wrote is kept
apart, in `serverMessage` and `logLines`, because it can quote arguments:
print it while debugging (for example a missing `auth:refreshSession`
export), but do not send it to telemetry.

A sign-in function of your own decides what its `userError.error` holds. A
sentence stays in `userError`: `code` is only set when the value is shaped
like a code (letters, digits, underscores). That shape is the only check, so
a single word is copied into `message` whatever it means. Put fixed
identifiers in `error`, never something the user typed.

## Security notes

- Requests carry credentials and refresh tokens. `ConvexAuthHttpClient`
  refuses a plain `http://` deployment URL unless the host is the local
  machine (`localhost`, a loopback address, or the Android emulator alias
  `10.0.2.2`); `allowInsecureHttp: true` lifts this for a development
  backend on another host.
- A session that the server reports gone during a background refresh signs
  the Convex client out with `dartvex` 0.4.0 or later. Earlier versions keep
  showing the user as signed in until the server rejects the access token.
- `ConvexAuthSession.toString()` and `ConvexAuthSignIn.toString()` omit
  tokens and arguments.

## Not supported yet

- **Passkeys and OAuth redirects:** these flows need platform code. Use
  `adoptSession` with a bundle you obtained yourself.
- **SSR mode:** in this mode the refresh token lives in an httpOnly cookie,
  which does not apply to native clients.
