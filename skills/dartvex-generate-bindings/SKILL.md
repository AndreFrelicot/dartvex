---
name: dartvex-generate-bindings
description: Generate type-safe Dart bindings for a Convex backend with dartvex_codegen - typed methods instead of raw function-name strings and maps. Use when setting up codegen, regenerating after backend changes, committing a function spec safely, or when the user mentions dartvex_codegen, function_spec.json, or typed Convex APIs in Dart.
license: MIT
metadata:
  author: AndreFrelicot
  ecosystem-version: "0.2.0"
---

# Generate Type-Safe Dart Bindings

`dartvex_codegen` reads a Convex *function spec* (the JSON description of
every public query/mutation/action and its validators) and generates a typed
Dart API, so calls are compile-checked instead of stringly-typed.

## Step 1 — Add the dev dependency

```yaml
dev_dependencies:
  dartvex_codegen: ^0.2.0
```

The app consuming the generated code needs `dartvex: ^0.2.0` (the bindings
call 0.2.0 APIs such as `paginatedQuery`).

## Step 2 — Generate

From a Convex TypeScript project on disk (runs `convex function-spec` for
you):

```bash
dart run dartvex_codegen generate \
  --project /path/to/convex-backend \
  --output lib/convex_api
```

Or from a previously exported spec file:

```bash
dart run dartvex_codegen generate \
  --spec-file function_spec.json \
  --output lib/convex_api
```

Useful flags: `--dry-run`, `--verbose`, `--watch`,
`--client-import package:dartvex/dartvex.dart`.

## Step 3 — SECURITY: scrub before committing a spec file

A raw `npx convex function-spec` dump **bakes the real deployment URL into
the JSON**. Never commit it raw. Always pipe through `scrub`:

```bash
npx convex function-spec | dart run dartvex_codegen scrub > function_spec.json
```

`scrub` replaces the top-level `url` with
`https://your-deployment.convex.cloud` (customize via `--placeholder-url`).
It is idempotent and preserves key order, so committed diffs stay minimal.
The placeholder is fine for generation — the URL in the spec is not used to
talk to the backend.

## Step 4 — Use the generated API

The generator emits `api.dart` (entrypoint), `runtime.dart` (helpers like
`Optional<T>`), `schema.dart` (typed table IDs), and `modules/...`:

```dart
import 'package:dartvex/dartvex.dart';
import 'package:my_app/convex_api/api.dart';

final client = ConvexClient(deploymentUrl);
final api = ConvexApi(client);

final messages = await api.messages.list();          // typed result
await api.messages.send(author: 'Andre', text: 'Hi'); // named, typed params
final sub = api.messages.listSubscribe();             // typed subscription
```

## Regeneration workflow

Regenerate whenever backend functions or validators change:

1. Backend changed → re-run Step 2 (and Step 3 if you commit the spec).
2. Treat generated files as build artifacts: do not hand-edit them; do not
   reformat them separately from regeneration.
3. `--watch` keeps bindings fresh during active backend development.

## Type mapping notes

- `v.number()` → `double`/`num`; `v.int64()` → `BigInt`.
- `v.id("table")` → a typed table ID from `schema.dart`.
- Literal unions become Dart enums; mixed unions and unknown/future Convex
  types degrade to `dynamic` with a warning rather than failing generation.
- Functions without arg/return validators parse as the Convex `any` type
  (args: `Map<String, dynamic>`, returns: `Future<dynamic>`).
- Paginated queries (taking `paginationOpts`) generate wrappers over the
  reactive pagination engine.

## Troubleshooting

- *"command not found: convex"* — run from a directory where the Convex CLI
  is installed, or export the spec on a machine that has it and use
  `--spec-file`.
- Generation aborts naming a function and field path
  (`messages.ts:list → args → field "x"`) — the spec has an unsupported
  construct there; check that the backend deploys cleanly first.
- For backend-side changes (adding validators so the bindings get real
  types), use the official Convex skills:
  `npx skills add get-convex/agent-skills`.
