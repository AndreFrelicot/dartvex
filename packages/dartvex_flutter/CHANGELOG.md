# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.3] - 2026-03-22

### Added

- `ConvexRuntimeClient.reconnectNow(String reason)` — propagate reconnect to the Flutter runtime layer.
- App lifecycle listener in `ConvexProvider` — automatically forces a reconnect when the app resumes from background if the connection is not active.

## [0.1.2] - 2026-03-21

### Improved

- Added comprehensive dartdoc comments on all public API
- Added example file for pub.dev scoring

## [0.1.1] - 2026-03-21

### Added

- `ConvexCachedImage` for disk-cached Convex storage images backed by `ConvexAssetCache`

### Fixed

- Asset cache test setup for publish validation
- Cached image analyzer warning cleanup

## [0.1.0] - 2026-03-15

### Added

- ConvexQuery reactive widget for query subscriptions
- ConvexMutation widget for executing mutations
- ConvexAction widget for action invocation
- ConvexProvider for dependency injection
- ConvexConnectionBuilder and ConvexConnectionIndicator
- ConvexAuthProvider and ConvexAuthBuilder
- ConvexImage widget for displaying storage images
- PaginatedQueryBuilder for cursor-based pagination
- FakeConvexClient test helper for testing
- ConvexOfflineImage with asset caching
- ConvexAssetCache for offline binary asset caching
- Runtime-interface based integration via ConvexClientRuntime
- Widget tests, example app, and package documentation
