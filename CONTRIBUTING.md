# Contributing to Dartvex

Thanks for your interest in contributing! Here's how to get started.

## Getting Started

1. Fork the repo and clone your fork
2. Run `dart pub get` in each package under `packages/`
3. Make your changes
4. Run `dart analyze` and `dart test` in the affected packages
5. Open a pull request

## Development

This is a monorepo with multiple packages:

| Package | Type | Test command |
|---------|------|-------------|
| `dartvex` | Dart | `dart test` |
| `dartvex_flutter` | Flutter | `flutter test` |
| `dartvex_codegen` | Dart | `dart test` |
| `dartvex_local` | Dart | `dart test` |
| `dartvex_auth_clerk` | Flutter | `flutter test` |
| `dartvex_auth_better` | Dart | `dart test` |

## Code Style

- Run `dart format .` before committing
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
