# Convex Demo Backend

This backend exists to demonstrate the Flutter SDK stack end to end.

It exposes:

- public queries and mutations
- authenticated queries and mutations
- a simple action
- Better Auth backed by Convex
- Convex Auth v2 (`@convex-dev/auth`) with the username/password method
- an optional custom JWT auth provider for the Flutter Demo auth mode and
  integration tests

## Security note (demo only)

This backend is **not production-hardened**. To keep the demo usable without
signing in, several functions are intentionally **unauthenticated** — e.g.
`messages:sendPublic` / `clearPublicMessages` and everything in `files.ts`
(including `add` and `clear`, which write to and can wipe stored blobs). Deploy
this to a throwaway dev deployment only, don't hand out its URL as if it were a
real service, and add `ctx.auth.getUserIdentity()` checks before reusing any of
these patterns in your own app.

## Install

Requires Node.js 22.9 or newer (Convex 1.49 dropped Node.js 20, and the pinned
`packageManager`, npm 11.5.2, needs Node.js >=22.9.0 on the 22 line). Use npm;
this example commits an npm `package-lock.json`.

Pinned auth stack: `better-auth` 1.7.17 (exact) with
`@convex-dev/better-auth` ^0.13.0 and `convex` ^1.49.0. Component 0.13
requires `better-auth` >=1.7.16 <1.8.0; keep the two in step when upgrading.
`dartvex_auth_better` releases before the `convex_jwt` cookie fix misread the
expired cookie that component 0.12.7+ sends on sign-in, so pair this backend
with a current `dartvex_auth_better`.

`@convex-dev/auth` is pinned to 2.0.0 (exact): `dartvex_auth2_convex` targets
the v2 protocol, whose functions and token rotation differ from v1.

```bash
cd example/convex-backend
npm install
```

## Convex Auth

The Flutter app's Convex Auth mode needs no secret and no variable of its
own: access tokens are signed by the deployment itself. Once the backend is
deployed (see [Run locally](#run-locally), which needs `DEMO_JWKS` set on a
new deployment), the mode works.

| File | Role |
|------|------|
| `convex/convex.config.ts` | Mounts the `auth`, `authPassword` and `authUsername` components. |
| `convex/auth.config.ts` | Accepts Convex Auth access tokens with `convexAuthProvider()`, next to the Better Auth and demo JWT providers. |
| `convex/convexAuth.ts` | Re-exports `signOut`, `refreshSession`, `isAuthenticated` and the username/password sign-up and sign-in mutations. |
| `convex/users.ts` | The app's `users` table callback (`createUserPassword`) and `users:viewer`, which resolves the caller with `getAuthUserId`. |
| `convex/identity.ts` | `requireOwner`, the key that scopes private data per user for every auth mode. |

Two things differ from a backend that only uses Convex Auth:

- The functions live in `convex/convexAuth.ts`, not `convex/auth.ts`, because
  Better Auth already uses that file. Their paths are `convexAuth:<name>`
  instead of the default `auth:<name>`, so the Flutter app passes them to the
  adapter (`refreshSessionFunction`, `signOutFunction`, and the `function` of
  each `ConvexAuthSignIn`).
- A Convex Auth access token names a **session**, not a user: its `subject`
  and `tokenIdentifier` change at every sign-in. Private messages are
  therefore keyed with `requireOwner`, which resolves the session to its user
  (`getAuthUserId`) and rejects a session that was revoked, even while its
  one-minute token is still valid. The demo JWT and Better Auth keep using
  `tokenIdentifier`, which is stable for them.

## Demo JWT provider

The custom JWT provider backs the Flutter app's Demo auth mode and the SDK
auth integration tests. Better Auth and Convex Auth do not use it, but its
public key set, `DEMO_JWKS`, has to be set before the backend can be deployed
at all: `convex/auth.config.ts` reads the variable, and Convex refuses a
config that reads an unset one (`Environment variable DEMO_JWKS is used in
auth config file but its value was not set`).

Generate local demo JWT material:

```bash
npm run demo:key
```

The script writes `.env` if it does not already exist, readable by your user
only, and prints the matching Convex command. The private key is written to
that file and never printed. Run the command to configure the public JWKS in
your dev deployment:

```bash
npx convex env set DEMO_JWKS '<value printed by npm run demo:key>'
```

Do not commit `.env`; it is gitignored and contains the private key. Only the
public `DEMO_JWKS` value belongs in the Convex deployment environment.
If `.env` already exists and you want to replace the demo keypair, run
`npm run demo:key -- --force`.

## Generate Convex types

```bash
npx convex codegen
```

## Refresh the versioned function spec

The committed `function_spec.json` drives the typed Dart bindings produced by
`packages/dartvex_codegen`. A raw `npx convex function-spec` dump bakes your
**real deployment URL** into the file, so never redirect it straight into the
committed spec. Instead, if your Convex deployment is configured locally, run:

```bash
bash ../refresh-function-spec.sh
```

That dumps the spec, pipes it through the codegen `scrub` subcommand to replace
the deployment URL with the `https://your-deployment.convex.cloud` placeholder,
writes `function_spec.json`, and regenerates the Dart bindings. Confirm the
result still uses the placeholder URL before committing.

## Run locally

```bash
npx convex dev
```

On a new deployment, the first run configures it and then stops because
`DEMO_JWKS` is not set. Set it as described in
[Demo JWT provider](#demo-jwt-provider), then run `npx convex dev` again.

## Generate a demo JWT

```bash
npm run token
```

The generated token is valid for the custom JWT provider configured in
`convex/auth.config.ts` when `DEMO_JWKS` is configured in Convex. It expires
after 24 hours; set `DEMO_TOKEN_TTL_SECONDS` for another lifetime (30 days at
most), and run `npm run token` again when it has expired.

Anyone holding the token is the demo user on that deployment until it
expires. Passing it with `--dart-define` compiles it into the app, where it
can be read back: do that for local runs only, never for a build you
distribute. If a token or the private key leaked, replace the keypair
(`npm run demo:key -- --force`) and set the new `DEMO_JWKS`.

Pass it to a local run of the Flutter demo with:

```bash
cd ../flutter_app
flutter run \
  --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud \
  --dart-define=CONVEX_DEMO_AUTH_TOKEN="$(cd ../convex-backend && npm run -s token)"
```
