<p align="center">
  <a href="https://github.com/AndreFrelicot/dartvex">
    <img src="https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-logo-512.png" width="128" alt="Dartvex" />
  </a>
</p>

# dartvex_codegen

CLI code generator for [Convex](https://convex.dev) backends. Generates type-safe Dart bindings from your Convex schema and function spec — companion tool to [`dartvex`](https://pub.dev/packages/dartvex).

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
| **[`dartvex_codegen`](https://pub.dev/packages/dartvex_codegen)** | CLI code generator — type-safe Dart bindings from schema |
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
`ConvexFunctionCaller.paginatedQuery` and `QueryLoading`), so the application
consuming the generated code needs:

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

Generate from a previously exported spec file:

```bash
dart run dartvex_codegen generate \
  --spec-file /path/to/function_spec.json \
  --output /path/to/dart_app/lib/convex_api
```

Useful flags:

- `--client-import package:dartvex/dartvex.dart`
- `--dry-run`
- `--verbose`
- `--watch`

Before committing an exported spec file, scrub the real deployment URL it
bakes in:

```bash
npx convex function-spec | dart run dartvex_codegen scrub > function_spec.json
```

`scrub` reads from stdin (or `--spec-file`) and writes the spec with the
top-level `url` replaced by `https://your-deployment.convex.cloud`
(customizable via `--placeholder-url`). The transform is idempotent and
preserves key order, so committed diffs stay minimal.

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

## How It Works

The public Dart API is the CLI entrypoint (`GenerateCommand` /
`runConvexCodegen`); the stages below are internal:

| Stage | Description |
|-------|-------------|
| `GenerateCommand` | Main CLI command for code generation |
| `SpecParser` | Parses Convex function_spec.json |
| `TypeMapper` | Maps Convex types to Dart types |
| `DartGenerator` | Generates Dart source from function specs |
| `FileEmitter` | Writes generated files to disk |

## Workflow

1. Keep your Convex backend in TypeScript.
2. Run `dartvex_codegen generate`.
3. Import the generated `api.dart` in your Dart or Flutter app.
4. Call typed wrappers instead of raw function names and raw maps.

## Full Documentation

See the [Dartvex monorepo](https://github.com/AndreFrelicot/dartvex) for full documentation and examples.
