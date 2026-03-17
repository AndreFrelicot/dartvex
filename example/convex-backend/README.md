# Convex Demo Backend

This backend exists to demonstrate the Flutter SDK stack end to end.

It exposes:

- public queries and mutations
- authenticated queries and mutations
- a simple action
- a self-contained custom JWT auth provider for demo use

## Install

```bash
cd demo/convex-backend
npm install
```

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
`convex/auth.config.ts`.
