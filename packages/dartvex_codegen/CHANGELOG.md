# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.5] - 2026-06-04

### Fixed

- Generated typed query subscriptions now include `TypedQueryLoading<T>` and
  handle `dartvex` `QueryLoading` events, keeping generated switches exhaustive
  with `dartvex` 0.2.x.
- CLI generation failures now return non-zero exit codes and print concise
  errors instead of leaking raw uncaught stack traces to callers.
- Escapes literal-union enum `fromJson` error messages so literal values with
  quotes, dollars, or newlines do not generate invalid Dart source.
- Fails code generation when a generated Dart file cannot be formatted instead
  of emitting invalid source with only a warning.
- Rejects Convex table names that would generate duplicate `ConvexTableId`
  subclasses in `schema.dart`.

### Changed

- Widen the `dartvex` dev-dependency to `^0.2.0` for golden fixture validation.
  Generated output is unchanged.

## [0.1.4] - 2026-05-13

### Fixed

- Rejects generated API member name collisions before writing invalid Dart.
- Uses `dartvex` 0.1.5 for golden fixture validation.
- Preserves existing camelCase boundaries in generated method and field names.
- Rejects missing `--output` paths before path normalization.

## [0.1.3] - 2026-04-30

### Improved

- Refreshed README metadata, logo links, installation snippets, and example
  commands for pub.dev.

## [0.1.2] - 2026-03-21

### Improved

- Added comprehensive dartdoc comments on all public API
- Added example file for pub.dev scoring

## [0.1.1] - 2026-03-21

### Fixed

- pub.dev validation for golden test fixtures that import `package:dartvex/dartvex.dart`

## [0.1.0] - 2026-03-15

### Added

- Type-safe Dart binding generation from Convex function specs
- CLI generate command with watch mode
- Typed query/mutation/action wrappers
- Schema types with table IDs
