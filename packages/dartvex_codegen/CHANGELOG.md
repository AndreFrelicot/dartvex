# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-11-05

### Added

- Supports the convex 1.43+/1.49 validator kinds: `v.commitTs()` maps to
  `BigInt` (`expectBigInt`) and `v.function()` handles map to `String`,
  instead of degrading to `dynamic` with an "Unknown Convex type" warning.
  **Breaking (regenerated bindings):** fields of these kinds change from
  `dynamic` to `BigInt` / `String`.
  **Breaking (library API):** the exported sealed `ConvexType` gains the
  `ConvexCommitTsType` and `ConvexFunctionHandleType` subclasses, so
  exhaustive switches over `ConvexType` need new cases.
- Generated mutation methods take an optional `OptimisticUpdate?
  optimisticUpdate` and forward it to `ConvexFunctionCaller.mutate`
  (positionally, matching `ConvexClient.mutate`). **Breaking:** regenerated
  bindings require `dartvex` `^0.3.0`, whose `ConvexFunctionCaller.mutate`
  accepts it; custom `ConvexFunctionCaller` implementations must add the
  parameter.
- `TypedQuerySuccess` now carries `hasPendingWrites` and `logLines` from the
  underlying `QuerySuccess`.
- Top-level `dartvex_codegen --help` (or `-h`, `help`) lists the `generate`
  and `scrub` commands and exits 0.
- `ProcessRunnerException` has an `exitCode`, and its `toString()` includes
  the last lines of the captured Convex CLI output.
- `FileEmitter.emit` accepts an `onWarning` callback.

### Fixed

- `--watch --project` now sees changes in nested directories on Linux, where
  `Directory.watch(recursive: true)` only watches the top level; every
  directory except `node_modules`, `.git`, `.dart_tool`, and the output
  directory is watched individually.
- `--watch --project` re-reads the deployed function spec 2, 5, and 10
  seconds after each change, so a `convex dev` push that finishes after the
  first regeneration no longer leaves stale bindings. Unchanged specs are not
  rewritten.
- Watch mode arms its filesystem watches before the initial generation (so
  edits made during it are not lost), keeps watching when the initial
  generation fails, and survives atomic replaces of a `--spec-file` (it
  watches the parent directory). A truncated, empty spec file is skipped
  silently. A watch error or a removed watched directory now exits non-zero
  with a concise message instead of hanging or crashing with an unhandled
  error.
- Generated union case classes no longer collide with nested types named
  from the same prefix (an object member's `value` field or a record member's
  values), which produced duplicate declarations that did not compile. Case
  class names are unchanged; the nested type gets a numeric suffix.
- Unions of distinct literals with the same runtime type plus another member
  (`v.union(v.literal('auto'), v.literal('none'), v.number())`) no longer
  fail as "Ambiguous union".
- An argument named like the return type (for example `result`) no longer
  aborts generation with a spurious "Name collision": table names are now
  collected without mapping types.
- `_id`/`_creationTime` next to user fields `id`/`creationTime` no longer
  abort generation; the system fields are generated as `systemId` and
  `systemCreationTime`.
- A system table whose ID class collides with a user table's (`_storage` and
  `storage`) no longer aborts generation; the system table's class gets a
  `System` prefix (`SystemStorageId`).
- Field and function names `toString`, `hashCode`, `runtimeType`, and
  `noSuchMethod` get a `Value` suffix instead of producing invalid record
  fields or overrides.
- Non-object top-level `args` validators (unions, records) generate an
  untyped `Map<String, dynamic>` argument with a warning instead of crashing
  the run with an uncaught `StateError`.
- Records keyed by `v.id(...)`, string literals, or unions of those keep
  their value type (`Map<String, V>`) instead of degrading to
  `Map<String, dynamic>` with a misleading "keys are not strings" warning.
  **Breaking (regenerated bindings):** such fields change type.
- **Breaking (behavior):** decode failures in generated subscriptions
  become `TypedQueryError` events instead of stream errors. `TypedConvexPaginatedQuery` reports
  undecodable items as `ConvexPaginationStatus.error` instead of throwing
  from `current`/`items` or erroring the stream.
- `TypedConvexPaginatedQuery.stream` returns the same stream on every access
  (a `StreamBuilder` no longer resubscribes on rebuild), and `current`/`items`
  decode each snapshot once. **Breaking:** `items` is now an unmodifiable
  list.
- Failing `convex function-spec` runs show the CLI's own error output (for
  example `No CONVEX_DEPLOYMENT set`) instead of only "failed in <dir>".
  Errors that merely contain "not found" (such as `Deployment "x" not found`)
  are no longer mistaken for a missing CLI and retried with other package
  runners.
- `scrub` and `generate --spec-file` accept the same noisy runner output
  (for example yarn v1 banners) that `--project` already tolerates.
- A corrupted or merge-conflicted generator manifest no longer breaks every
  run with an opaque `FormatException`; it is ignored with a warning and
  rewritten. The manifest is now written atomically.
- Unknown types inside internal functions, which are never generated, no
  longer produce warnings.
- Warnings and watch-mode errors go to stderr, so `--dry-run` output stays
  clean. Unknown commands print usage to stderr.
- `--watch --project` matches the output directory however a symlink spells
  it (macOS `/var` vs `/private/var`, or a relative `--output` resolved
  against the real current directory while `--project` names a symlink), so
  writing the bindings no longer triggers another regeneration or, on Linux,
  a watch of the output directory. Ignored directory names (`node_modules`,
  `.git`, `.dart_tool`) only count below the project directory, so a project
  that itself lives under such a directory is still watched.

### Changed

- Generated subscriptions delegate to a new `typedQueryResult` helper in the
  generated `runtime.dart`.
- Package descriptions now say bindings are generated from the function spec
  validators rather than "from your Convex schema".
- The README documents watch-mode behavior, type-mapping rules, naming
  rules, custom `ConvexFunctionCaller` clients, and that the exported
  pipeline stages are not yet a stable API.
- Removed the duplicate `test/update_goldens.dart`; use
  `dart run tool/update_goldens.dart`.
- README and example: the bindings come from the functions deployed to the
  project's deployment (`convex function-spec`), not from local sources;
  documents the generated result types and which clients `ConvexApi`
  accepts, and the example shows the real generated shape.

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
- **Breaking (noted after release):** regenerated bindings changed in this
  release: the sealed `TypedQueryResult` gained a `TypedQueryLoading` case
  (exhaustive `switch`es need a new branch), paginated queries generate
  typed wrappers, and the output requires `dartvex` `^0.2.0` (`QueryLoading`,
  `ConvexFunctionCaller.paginatedQuery`).
- Require Dart `^3.7.0`, matching the minimum SDK required by the
  `dart_style` formatter versions accepted by the CLI.

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
