# Example Stack

This directory contains the end-to-end example for the repo:

- `convex-backend/` — Convex TypeScript backend
- `flutter_app/` — Flutter app using `dartvex`, `dartvex_codegen`, and
  `dartvex_flutter`

## Why the backend includes `function_spec.json`

`packages/dartvex_codegen` normally expects `convex function-spec`.

In practice, the Convex CLI currently requires a configured deployment before it
will emit that spec. To keep this repo reproducible without assuming your local
Convex project is already configured, the example checks in a versioned
`function_spec.json` derived from the demo backend contract.

Once your backend is configured, you can refresh it with:

```bash
cd example/convex-backend
npx convex function-spec > function_spec.json
```

## Generate Dart bindings

From the repo root:

```bash
bash example/generate_bindings.sh
```

## Run the backend

```bash
cd example/convex-backend
npm install
npx convex dev
```

## Generate a demo JWT

```bash
cd example/convex-backend
npm run token
```

The Flutter app also includes a bundled demo token for convenience.

## Run the Flutter app

```bash
cd example/flutter_app
flutter pub get
flutter run \
  --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud
```

Optional auth token at startup:

```bash
flutter run \
  --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud \
  --dart-define=CONVEX_DEMO_AUTH_TOKEN="$(cd ../convex-backend && npm run -s token)"
```
