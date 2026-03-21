# dartvex_codegen

CLI code generator for [Convex](https://convex.dev) backends. Generates type-safe Dart bindings from your Convex schema and function spec.

## Installation

```yaml
dev_dependencies:
  dartvex_codegen: ^0.1.1
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
