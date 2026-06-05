# Convex Demo Backend

This backend exists to demonstrate the Flutter SDK stack end to end.

It exposes:

- public queries and mutations
- authenticated queries and mutations
- a simple action
- Better Auth backed by Convex
- an optional custom JWT auth provider for integration tests

## Install

```bash
cd example/convex-backend
npm install
```

## Optional demo JWT provider

Better Auth works without this step. Use the custom JWT provider only when you
want to run the SDK auth integration tests with a static token.

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

Do not commit `.env`; it is gitignored.
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
