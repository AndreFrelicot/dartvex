---
name: dartvex-generate-bindings
description: Generate type-safe Dart bindings for a Convex backend with dartvex_codegen - typed methods instead of raw function-name strings and maps. Use when setting up codegen, regenerating after backend changes, committing a function spec safely, or when the user mentions dartvex_codegen, function_spec.json, or typed Convex APIs in Dart.
license: MIT
metadata:
  author: AndreFrelicot
  ecosystem-version: "0.3.0"
---

# Generate Type-Safe Dart Bindings

`dartvex_codegen` reads a Convex *function spec* — the JSON description of
every public query/mutation/action and its `args`/`returns` validators, as
produced by `npx convex function-spec` — and generates a typed Dart API, so
calls are compile-checked instead of stringly-typed.

The spec describes the functions **deployed** to a deployment, not your local
TypeScript files: bindings only reflect a change once it has been pushed
(`npx convex dev` or `npx convex deploy`). Functions without validators
generate untyped (`dynamic`) methods, so add `args`/`returns` validators to
get real types.

## Step 1 — Add the dev dependency

```yaml
dev_dependencies:
  dartvex_codegen: ^0.3.0
```

The app consuming the generated code needs `dartvex: ^0.3.0` (generated
mutations forward an optional `optimisticUpdate` to
`ConvexFunctionCaller.mutate`, which 0.3.0 added).

## Step 2 — Generate

From a Convex project directory (the one with `package.json` and
`.env.local`; the tool runs `convex function-spec` there, against that
project's configured dev deployment):

```bash
npx convex dev --once   # push first, so the deployment matches your code
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

Useful flags: `--dry-run` (files to stdout, warnings to stderr), `--verbose`
(show the Convex CLI output), `--watch`,
`--client-import package:dartvex/dartvex.dart`. `dart run dartvex_codegen
--help` lists the commands (`generate`, `scrub`).

### Watch mode caveats

- `--watch --spec-file` regenerates when that file is rewritten.
- `--watch --project` regenerates when files in the project change, but the
  spec still comes from the deployment: it re-reads it 2, 5 and 10 seconds
  after each change so a `convex dev` push that lands later is picked up.
  A slower push can leave stale bindings — save again or rerun `generate`.

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

The generator emits `api.dart` (entrypoint `ConvexApi`), `runtime.dart`
(`Optional<T>`, `TypedQueryResult`, typed subscription/pagination wrappers),
`schema.dart` (typed table IDs such as `MessagesId`), and `modules/...`:

```dart
import 'package:dartvex/dartvex.dart';
import 'package:my_app/convex_api/api.dart';
import 'package:my_app/convex_api/runtime.dart';

final client = ConvexClient(deploymentUrl);
final api = ConvexApi(client);

final messages = await api.messages.list();            // typed result
final id = await api.messages.send(author: 'Andre', text: 'Hi'); // MessagesId
await api.messages.send(
  author: 'Andre',
  text: 'Hi',
  optimisticUpdate: (store) {/* overlay cached query results */},
);

final sub = api.messages.listSubscribe();               // typed subscription
sub.stream.listen((result) {
  switch (result) {
    case TypedQuerySuccess(:final value):
      print(value.length);
    case TypedQueryLoading():
      break; // transient (optimistic clear); a result follows
    case TypedQueryError(:final message):
      print(message); // server error, or a value the bindings cannot decode
  }
});
// Later: sub.cancel();
```

Optional arguments are `Optional<T>` (`Optional.of(v)` / omitted), so
"absent" and "explicit null" stay distinct. Paginated queries return a
`TypedConvexPaginatedQuery<T>` (`stream`, `current`, `items`, `loadMore`,
`cancel`).

### Which clients ConvexApi accepts

`ConvexApi` wraps a core `ConvexFunctionCaller`: `ConvexClient` or
`ConvexClientWithAuth`.

- Below a `ConvexProvider` (Flutter):
  `ConvexApi(ConvexProvider.of(context).functionCaller)` — works with
  `ConvexClientRuntime` and with `FakeConvexClient` in widget tests (the fake
  serves `whenQuery`/`whenMutation` stubs; its `paginatedQuery` is
  unsupported).
- `ConvexLocalClient` (dartvex_local) is **not** a `ConvexFunctionCaller`
  (its `mutate` returns a `LocalMutationResult`). Typed calls through the
  underlying `ConvexClient` bypass the offline cache and queue.

## Regeneration workflow

Regenerate whenever backend functions or validators change:

1. Push the backend change, then re-run Step 2 (and Step 3 if you commit the
   spec).
2. Treat generated files as build artifacts: do not hand-edit them; do not
   reformat them separately from regeneration.
3. After upgrading `dartvex_codegen`, regenerate and fix compile errors —
   new releases can change generated types (see its CHANGELOG).

## Type mapping notes

- `v.number()` → `double` (always); `v.int64()` → `BigInt`;
  `v.commitTs()` → `Object` (a `BigInt`, or `ConvexCommitTsPlaceholder.instance`
  when a mutation returns a field it just wrote with `db.vars.commitTs`);
  `v.bytes()` → `Uint8List`; `v.any()` → `dynamic`.
- `v.id("table")` → the typed `<Table>Id` from `schema.dart`;
  `v.function()` handles → `String`.
- Unions of literals → Dart enums. Other unions → a sealed class with one
  `<Union><n>Value` case per member (e.g. `v.union(v.string(), v.number())`
  gives `...1Value(String)` / `...2Value(double)`), as long as the members
  can be told apart at runtime. Members with the same runtime shape (e.g.
  `v.string()` and `v.id(...)`, or objects without a distinct literal
  discriminator) **abort generation** with an "Ambiguous union" error — add a
  literal discriminator field.
- Records with string, id, or literal-union keys → `Map<String, V>`.
- Only unknown/future validator kinds and non-scalar literals fall back to
  `dynamic`, with a warning.
- Functions without arg/return validators parse as the Convex `any` type
  (args: `Map<String, dynamic>`, returns: `dynamic`).
- Field names become camelCase; a system field colliding with a user field
  (`_id` next to `id`) becomes `systemId` / `systemCreationTime`. Dart
  keywords and `Object` members get a `Value` (member) or `Type` (type name)
  suffix (`kv:set` → `setValue()`).
- Type names come from the function name, not the module path: two modules
  exporting `list` each declare a `ListResult` — use import prefixes if one
  file needs both.

## Troubleshooting

- *"command not found: convex"* — run from a directory where the Convex CLI
  is installed, or export the spec on a machine that has it and use
  `--spec-file`.
- *`No CONVEX_DEPLOYMENT set`* (shown by the tool) — run `npx convex dev`
  once in that project to configure a deployment, or use `--spec-file`.
- Bindings miss a recent change — the change was not pushed yet (see Step 2).
- Generation aborts naming a function and field path
  (`messages.ts:list → args → field "x"`) — the spec has an unsupported or
  ambiguous construct there.
- For backend-side changes (adding validators so the bindings get real
  types), use the official Convex skills:
  `npx skills add convex/agent-skills`.
