<p align="center">
  <img src="https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-logo-128.png" width="128" alt="Dartvex" />
</p>

# dartvex_codegen

CLI code generator for [Convex](https://convex.dev) backends. Generates type-safe Dart bindings from your Convex schema and function spec — companion tool to [`dartvex`](https://pub.dev/packages/dartvex).

## The Dartvex ecosystem

| Package | Description |
|---------|-------------|
| [`dartvex`](https://pub.dev/packages/dartvex) | Core client — WebSocket sync, subscriptions, auth |
| [`dartvex_flutter`](https://pub.dev/packages/dartvex_flutter) | Flutter widgets — Provider, QueryBuilder, MutationBuilder |
| **[`dartvex_codegen`](https://pub.dev/packages/dartvex_codegen)** | CLI code generator — type-safe Dart bindings from schema |
| [`dartvex_local`](https://pub.dev/packages/dartvex_local) | Offline support — SQLite cache, mutation queue |
| [`dartvex_auth_better`](https://pub.dev/packages/dartvex_auth_better) | Better Auth adapter |

Source and full docs: [github.com/AndreFrelicot/dartvex](https://github.com/AndreFrelicot/dartvex)

## Installation

```yaml
dev_dependencies:
  dartvex_codegen: ^0.1.2
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

final client = ConvexClient('https://example.convex.cloud');
final api = ConvexApi(client);

final messages = await api.messages.list();
await api.messages.send(author: 'Andre', text: 'Hello');
final subscription = api.messages.listSubscribe();
```

## API Overview

| Class | Description |
|-------|-------------|
| `GenerateCommand` | Main CLI command for code generation |
| `DartGenerator` | Generates Dart source from function specs |
| `FileEmitter` | Writes generated files to disk |
| `SpecParser` | Parses Convex function_spec.json |
| `TypeMapper` | Maps Convex types to Dart types |

## Workflow

1. Keep your Convex backend in TypeScript.
2. Run `dartvex_codegen generate`.
3. Import the generated `api.dart` in your Dart or Flutter app.
4. Call typed wrappers instead of raw function names and raw maps.

## Full Documentation

See the [Dartvex monorepo](https://github.com/AndreFrelicot/dartvex) for full documentation and examples.
