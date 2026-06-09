# Convex Demo Backend

This backend exists to demonstrate the Flutter SDK stack end to end.

It exposes:

- public queries and mutations
- authenticated queries and mutations
- a simple action
- Better Auth backed by Convex
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

```bash
cd example/convex-backend
npm install
```

## Optional demo JWT provider

Better Auth works without this step. Use the custom JWT provider only when you
want to run the Flutter app's Demo auth mode or the SDK auth integration tests
with a static token.

Generate local demo JWT material:

```bash
npm run demo:key
```

The script writes `.env` if it does not already exist and prints the matching
Convex command. Run that command to configure the public JWKS in your dev
deployment:

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

If your Convex deployment is configured locally, you can refresh the spec used
by `packages/convex_codegen` with:

```bash
npx convex function-spec > function_spec.json
```

## Run locally

```bash
npx convex dev
```

## Generate a demo JWT

```bash
npm run token
```

The generated token is valid for the custom JWT provider configured in
`convex/auth.config.ts` when `DEMO_JWKS` is configured in Convex.

Pass it to the Flutter demo with:

```bash
cd ../flutter_app
flutter run \
  --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud \
  --dart-define=CONVEX_DEMO_AUTH_TOKEN="$(cd ../convex-backend && npm run -s token)"
```
