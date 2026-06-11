# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-06-12

### Added

- Tolerates raw `convex function-spec` dumps: absent or `null` `args`/`returns`
  parse as the Convex `any` type (a returns-less function generates
  `Future<dynamic>`; an unvalidated-args function takes a
  `Map<String, dynamic>` argument) instead of aborting generation.
- Unknown/future Convex type tags and non-scalar literal values (such as
  `$integer`-encoded bigint literals) degrade to `dynamic` with a warning
  instead of crashing the run.
- Spec parse errors now name the offending function and field path
  (`messages.ts:list → args → field "filters"`).
- `dartvex_codegen scrub` subcommand and `scrubFunctionSpec`: replace the real
  deployment URL in a function-spec dump with a placeholder before the file is
  committed.
- Typed paginated query bindings: a query taking `paginationOpts` and returning
  a `PaginationResult` shape generates a
  `TypedConvexPaginatedQuery<PageItem>` wrapper (typed page items when a
  `returns:` validator exists, `Map<String, dynamic>` items otherwise),
  exposing `items`, `stream`, `status`, `isDone`, `loadMore`, and `cancel`.
- Generated files carry an `ignore_for_file` line under the generated-code
  header, so projects that do not exclude the generated directory from
  analysis do not fail on unused generated helpers or imports.

### Fixed

- Encoding an optional field with a nullable composite type (for example
  `v.optional(v.union(v.id('users'), v.null()))`) generated Dart that did not
  compile; nullable encodes now bind through a promoting switch expression.
- Generated locals no longer collide with user argument names: arguments named
  `raw`, `value`, `subscription`, or `query` (for example `kv.set(key, value)`
  or a paginated `search(query)`) previously generated code that failed to
  compile.
- A paginated query with an argument that sanitizes to `pageSize` falls back
  to a plain query method with a warning instead of declaring the parameter
  twice.
- Unions of only null members (including `v.literal(null)`) map to `Null`
  instead of rendering an empty Dart enum, and nested nullable unions no
  longer emit invalid `T??` annotations.
- NUL characters in string literals are escaped as `\x00`; Dart has no `\0`
  escape, so the previous output silently matched the digit `'0'`.
- Generated typed query subscriptions now include `TypedQueryLoading<T>` and
  handle `dartvex` `QueryLoading` events, keeping generated switches exhaustive
  with `dartvex` 0.2.x.
- CLI generation failures now return non-zero exit codes and print concise
  errors instead of leaking raw uncaught stack traces to callers.
- Escapes literal-union enum `fromJson` error messages so literal values with
  quotes, dollars, or newlines do not generate invalid Dart source.
- Escapes generated imports, Convex function names, and table names embedded in
  Dart string literals, so unusual but valid identifiers containing quotes,
  dollars, or control characters do not produce analyzer-broken bindings.
- Deduplicates repeated literal union members before rendering enum decoders, so
  redundant validators cannot generate duplicate Dart `switch` cases.
- Rejects unsafe generated file paths from malformed function specs or stale
  manifests instead of writing or deleting files outside the configured output
  directory.
- Fails code generation when a generated Dart file cannot be formatted instead
  of emitting invalid source with only a warning.
- Rejects Convex table names that would generate duplicate `ConvexTableId`
  subclasses in `schema.dart`.
- Rejects generated API member name collisions before writing invalid Dart.
- Preserves existing camelCase boundaries in generated method and field names.
- Rejects missing `--output` paths before path normalization.

### Changed

- Widen the `dartvex` dev-dependency to `^0.2.0` for golden fixture validation.
  Generated output is unchanged.

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
