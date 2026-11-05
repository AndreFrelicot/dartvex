# Contributing to Dartvex

Thanks for your interest in contributing! Here's how to get started.

## Getting Started

1. Fork the repo and clone your fork
2. For each package you work on, point its internal Dartvex dependencies at
   the local checkout, then fetch dependencies:

   ```sh
   bash scripts/ci-local-dependency-overrides.sh packages/dartvex_flutter
   cd packages/dartvex_flutter && flutter pub get
   ```

   The script writes a gitignored `pubspec_overrides.yaml`, so packages are
   tested against the unreleased `dartvex` on your branch rather than the
   pub.dev release. Use `flutter pub get` for `dartvex_flutter` and the
   Flutter examples, `dart pub get` elsewhere.
3. Make your changes
4. Run the same checks as CI in the affected packages: `dart format`,
   `dart analyze --fatal-infos` (`flutter analyze --fatal-infos` for
   Flutter packages), and `dart test` (`flutter test`)
5. Open a pull request

`flutter pub get` and `flutter analyze` may rewrite `analysis_options.yaml`;
do not commit those rewrites.

## Development

This is a monorepo with multiple packages:

| Package | Type | Test command |
|---------|------|-------------|
| `dartvex` | Dart | `dart test` |
| `dartvex_flutter` | Flutter | `flutter test` |
| `dartvex_codegen` | Dart | `dart test` |
| `dartvex_local` | Dart | `dart test` |
| `dartvex_auth_better` | Dart | `dart test` |

## Code Style

- Run `dart format .` before committing (CI runs
  `dart format --set-exit-if-changed`)
- Follow the [Effective Dart](https://dart.dev/effective-dart) guidelines
- Add dartdoc comments to all public APIs

## Pull Requests

- Keep PRs focused on a single change
- Include tests for new functionality
- Ensure CI passes (format, analyze, test)
- Write a clear description of what changed and why

## Releases

Use the monorepo release helper in [`scripts/release_packages.dart`](scripts/release_packages.dart)
to detect changed packages, surface impacted internal dependents, and run
pub.dev dry-runs in publish order.

See [`RELEASING.md`](RELEASING.md) for the full workflow.

## Reporting Issues

Open an issue with:
- Steps to reproduce
- Expected vs actual behavior
- Dart/Flutter version and platform

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
