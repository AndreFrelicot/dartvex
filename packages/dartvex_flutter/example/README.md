# dartvex_flutter Example

Flutter example app for the `dartvex_flutter` package.

The app uses an in-memory `ConvexRuntimeClient` so the package widgets can be
run, tested, and built without a live Convex deployment. Replace the demo
runtime with `ConvexClientRuntime` when wiring a real backend.

## Run

```bash
flutter run
```

## Test

```bash
flutter test
flutter build web --no-wasm-dry-run
```
