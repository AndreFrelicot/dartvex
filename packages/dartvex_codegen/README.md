<p align="center">
  <a href="https://github.com/AndreFrelicot/dartvex">
    <img src="https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-logo-512.png" width="128" alt="Dartvex" />
  </a>
</p>

# dartvex_codegen

CLI code generator for [Convex](https://convex.dev) backends. Generates type-safe Dart bindings from your Convex function spec (the `args` and `returns` validators of your public functions) — companion tool to [`dartvex`](https://pub.dev/packages/dartvex).

<p align="center">
  <a href="https://github.com/AndreFrelicot/dartvex">
    <img src="https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-poster.webp" width="900" alt="Dartvex Flutter demo — real-time chats running on iOS and macOS" />
  </a>
</p>

## The Dartvex ecosystem

| Package | Description |
|---------|-------------|
| [`dartvex`](https://pub.dev/packages/dartvex) | Core client — WebSocket sync, subscriptions, auth |
| [`dartvex_flutter`](https://pub.dev/packages/dartvex_flutter) | Flutter widgets — Provider, Query, Mutation |
| **[`dartvex_codegen`](https://pub.dev/packages/dartvex_codegen)** | CLI code generator — type-safe Dart bindings from function validators |
| [`dartvex_local`](https://pub.dev/packages/dartvex_local) | Offline support — SQLite cache, mutation queue |
| [`dartvex_auth_better`](https://pub.dev/packages/dartvex_auth_better) | Better Auth adapter |

Source and full docs: [github.com/AndreFrelicot/dartvex](https://github.com/AndreFrelicot/dartvex)

## Installation

```yaml
dev_dependencies:
  dartvex_codegen: ^0.2.0
```

Requires Dart `^3.7.0`.

The generated bindings call APIs introduced in `dartvex` 0.2.0 (such as
`ConvexFunctionCaller.paginatedQuery` and `QueryLoading`), and generated
mutations forward an optional optimistic update to
`ConvexFunctionCaller.mutate`, so use the `dartvex` release that matches this
generator. The application consuming the generated code needs:

```yaml
dependencies:
  dartvex: ^0.2.0
```

## Usage

Generate from an existing Convex TypeScript project:

```bash
dart run dartvex_codegen generate \
  --project /path/to/convex-backend \
  --output /path/to/dart_app/lib/convex_api
```

`--project` runs `convex function-spec` in that directory, which lists the
functions **deployed** to the project's configured (dev) deployment, not the
local TypeScript sources. Push your changes first (keep `npx convex dev`
running) so the bindings match your code.

Generate from a previously exported spec file:

```bash
dart run dartvex_codegen generate \
  --spec-file /path/to/function_spec.json \
  --output /path/to/dart_app/lib/convex_api
```

Useful flags:

- `--client-import package:dartvex/dartvex.dart`
- `--dry-run` (generated files go to stdout; warnings go to stderr)
- `--verbose` (show the Convex CLI output)
- `--watch`

Run `dart run dartvex_codegen --help` to list the commands (`generate`,
`scrub`) and `dart run dartvex_codegen generate --help` for every option.

### Watch mode

`--watch` regenerates whenever its input changes:

- With `--spec-file`, it reacts to rewrites of that file, including atomic
  replaces (`git pull`, editor safe-writes, `mv`). An empty file (a shell
  redirect that has not been written yet) is skipped silently.
- With `--project`, it watches the project directory recursively (including
  on Linux, where each directory is watched individually; `node_modules`,
  `.git`, `.dart_tool`, and the output directory are skipped). Because the
  spec comes from the deployment, it re-reads it 2, 5, and 10 seconds after
  each change so a `convex dev` push that finishes after the first
  regeneration is still picked up; unchanged specs are not rewritten. If a
  push takes longer, save again or rerun `generate`.

Failed regenerations are reported on stderr and watching continues. If the
watch itself fails (for example, the watched directory is removed), the
command exits with a non-zero code.
Before committing an exported spec file, scrub the real deployment URL it
bakes in:

```bash
npx convex function-spec | dart run dartvex_codegen scrub > function_spec.json
```

`scrub` reads from stdin (or `--spec-file`) and writes the spec with the
top-level `url` replaced by `https://your-deployment.convex.cloud`
(customizable via `--placeholder-url`). The transform is idempotent and
preserves key order, so committed diffs stay minimal. Like `--project`,
`scrub` and `generate --spec-file` skip banner lines that package runners
such as yarn v1 print around the JSON.

## Generated API

The generator produces:

- `api.dart` as the main entrypoint
- `runtime.dart` with shared helper types like `Optional<T>`
- `schema.dart` with typed table IDs
- `modules/...` with typed wrappers around Convex queries, mutations, and actions

Example:

```dart
import 'package:dartvex/dartvex.dart';
import 'package:my_app/convex_api/api.dart';

final client = ConvexClient('https://your-deployment.convex.cloud');
final api = ConvexApi(client);

final messages = await api.messages.list();
await api.messages.send(author: 'Andre', text: 'Hello');
final subscription = api.messages.listSubscribe();
```

Typed subscriptions emit `TypedQuerySuccess` (with `hasPendingWrites` and
`logLines`), `TypedQueryLoading`, and `TypedQueryError`. A server value the
bindings cannot decode (for example an enum value added after generation)
arrives as a `TypedQueryError` rather than a stream error. Typed paginated
queries report undecodable items as `ConvexPaginationStatus.error`.

Generated mutation methods take an optional `optimisticUpdate`, forwarded to
the client's `mutate`:

```dart
await api.messages.send(
  author: 'Andre',
  text: 'Hello',
  optimisticUpdate: (store) {
    // Update cached query results through the OptimisticLocalStore.
  },
);
```

### Type mapping notes

- `v.number()` maps to `double`; `v.int64()` and `v.commitTs()` map to
  `BigInt`; `v.id("table")` maps to the generated `<Table>Id` class;
  `v.function()` handles map to `String`; `v.any()` maps to `dynamic`.
- Unions of literals become enums. Other unions become a sealed class with
  one `<Union><n>Value` case per member, as long as Dart can tell the members
  apart at runtime. Members with the same runtime shape (for example
  `v.string()` and `v.id("users")`, or objects without a distinct literal
  discriminator field) make generation fail with an "Ambiguous union" error.
- Records with string, id, or literal-union keys become `Map<String, V>`.
- Field names are converted to camelCase. If a system field collides with a
  user field (`_id` next to `id`), the system field is renamed (`systemId`,
  `systemCreationTime`). Likewise, a system table whose ID class would
  collide with a user table's (`_storage` and `storage`) gets a `System`
  prefix (`SystemStorageId`).
- Names that are Dart keywords or built-in identifiers (`get`, `set`,
  `sync`, ...) or `Object` members (`toString`, `hashCode`, ...) get a
  `Value` suffix for members and a `Type` suffix for type names (`kv:set`
  generates `setValue()` with `SetTypeArgs`). These names are kept for
  compatibility with existing bindings.
- Generated type names come from the function name, not its module path, so
  two modules that both export `list` each declare a `ListResult`. Use import
  prefixes if one Dart file needs both.

### Using other clients

The generated API classes wrap a `ConvexFunctionCaller`, which `ConvexClient`
implements. To call the bindings through another client (a test fake, or an
adapter over a Flutter runtime or offline client), implement
`ConvexFunctionCaller` and pass it to `ConvexApi`. `--client-import` lets the
generated files import that interface (plus `QueryResult`,
`ConvexSubscription`, `ConvexPaginatedQuery`, and `OptimisticUpdate`) from a
library of your own that re-exports them.

## How It Works

| Stage | Description |
|-------|-------------|
| `GenerateCommand` | Main CLI command for code generation |
| `SpecParser` | Parses Convex function_spec.json |
| `TypeMapper` | Maps Convex types to Dart types |
| `DartGenerator` | Generates Dart source from function specs |
| `FileEmitter` | Writes generated files to disk |

The CLI (`dart run dartvex_codegen`, or `runConvexCodegen` /
`GenerateCommand`) is the supported interface. The library also exports the
pipeline stages above and their helper types for programmatic use, but
while the package is pre-1.0 they may change in minor releases.

## Workflow

1. Keep your Convex backend in TypeScript.
2. Run `dartvex_codegen generate`.
3. Import the generated `api.dart` in your Dart or Flutter app.
4. Call typed wrappers instead of raw function names and raw maps.

## Full Documentation

See the [Dartvex monorepo](https://github.com/AndreFrelicot/dartvex) for full documentation and examples.
