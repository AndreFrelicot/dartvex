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

Once your backend is configured, refresh it through the scrub script so the
committed spec keeps the placeholder deployment URL:

```bash
bash example/refresh-function-spec.sh
```

## Generate Dart bindings

From the repo root:

```bash
bash example/generate_bindings.sh
```

## Run the backend

The backend example requires Node.js 20.19.0 or newer and uses npm with the
committed `package-lock.json`.

```bash
cd example/convex-backend
npm install
npx convex dev
```

## Generate a demo JWT

Demo auth uses a custom JWT provider. Better Auth and the public screens work
without this step, but the Flutter app's Demo auth mode needs a token generated
from local key material.

```bash
cd example/convex-backend
npm run demo:key
```

The script writes the private key to gitignored `.env` and prints the matching
`npx convex env set DEMO_JWKS ...` command. Run that command once for your
deployment, then generate a token when launching Flutter:

```bash
npm run -s token
```

Do not commit `.env`, generated JWTs, or real deployment URLs.

## Run the Flutter app

```bash
cd example/flutter_app
flutter pub get
flutter run \
  --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud
```

Demo auth token at startup — capture the token in a shell variable first (it is
~400 characters; pasting it directly is fragile). See the Flutter app README's
Troubleshooting and Standalone builds sections for details:

```bash
TOKEN="$(cd ../convex-backend && npm run -s token)"
flutter run \
  --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud \
  --dart-define=CONVEX_DEMO_AUTH_TOKEN="$TOKEN"
```
