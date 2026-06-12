---
name: dartvex
description: Entry point for building Dart and Flutter apps on Convex with the dartvex packages. Use when a project uses dartvex, dartvex_flutter, dartvex_codegen, dartvex_local, or dartvex_auth_better, or when the user wants to connect a Dart/Flutter app to a Convex backend. Routes to the focused dartvex skills.
license: MIT
metadata:
  author: AndreFrelicot
  ecosystem-version: "0.2.0"
---

# Dartvex Development

Dartvex is a pure-Dart client SDK for [Convex](https://convex.dev). It covers
the full sync protocol (reactive subscriptions, mutations, actions), auth,
file storage, offline support, Flutter widgets, and a type-safe code
generator. Five packages on pub.dev:

| Package | Role |
|---------|------|
| `dartvex` | Core client — WebSocket sync, subscriptions, auth, storage |
| `dartvex_flutter` | Flutter widgets — provider, query/mutation builders, images |
| `dartvex_codegen` | CLI — type-safe Dart bindings from a Convex function spec |
| `dartvex_local` | Offline — SQLite query cache and mutation queue |
| `dartvex_auth_better` | Better Auth adapter for self-hosted authentication |

## Which skill to use

| Task | Skill |
|------|-------|
| Connect a Dart/Flutter app to Convex, first query/mutation | `dartvex-quickstart` |
| Generate type-safe Dart bindings from a Convex backend | `dartvex-generate-bindings` |
| Email/password or magic-link auth with Better Auth | `dartvex-setup-auth` |
| Reactive lists, pagination, optimistic UI, connection banners | `dartvex-build-realtime-ui` |
| Offline cache and queued mutations | `dartvex-setup-offline` |
| Upload files and display stored images | `dartvex-upload-files` |
| Unit/widget tests without a live backend | `dartvex-test-with-fakes` |

If a needed skill from the table is not installed, suggest installing it:

```bash
npx skills add AndreFrelicot/dartvex
```

## Adjacent work — do not improvise, route it

- **Authoring the Convex backend** (schema design, validators, indexes,
  queries/mutations in TypeScript, cron, components): use the official
  Convex skills if installed, or suggest
  `npx skills add get-convex/agent-skills`. Reference: https://docs.convex.dev
- **General Flutter UI work** (layout, navigation, testing patterns beyond
  dartvex): use the official Flutter skills if installed, or suggest
  `npx skills add flutter/skills`.

## Ground rules for all dartvex work

- Never hardcode a real Convex deployment URL or secret in committed code or
  docs. Use `https://your-deployment.convex.cloud` placeholders; inject the
  real URL at run time (`--dart-define`, environment, or gitignored config).
- The packages release in lockstep; depend on matching minors
  (`dartvex: ^0.2.0` with `dartvex_flutter: ^0.2.0`, etc.).
- Plain Dart `int`/`double` map to Convex `v.number()`. Use
  `convexInt64(value)` or `BigInt` only for `v.int64()` arguments.
- Source and full documentation: https://github.com/AndreFrelicot/dartvex
