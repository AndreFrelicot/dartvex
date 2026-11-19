# Example Stack

This directory contains the end-to-end example for the repo:

- `convex-backend/` — Convex TypeScript backend
- `flutter_app/` — Flutter app using `dartvex`, `dartvex_codegen`,
  `dartvex_flutter`, `dartvex_local` and the two auth adapters
  (`dartvex_auth_better`, `dartvex_auth2_convex`)

The app's `Auth` tab switches between three auth modes: a demo JWT, Better
Auth, and Convex Auth v2. The backend serves all three from one deployment.

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

The backend example requires Node.js 22.9 or newer and uses npm with the
committed `package-lock.json`.

```bash
cd example/convex-backend
npm install
npm run demo:key   # prints an `npx convex env set DEMO_JWKS ...` command
npx convex dev
```

On a new deployment the first `npx convex dev` configures it, then reports
`Environment variable DEMO_JWKS is used in auth config file but its value was
not set`: `convex/auth.config.ts` reads that variable for the Demo auth mode,
and Convex refuses a config that reads an unset variable, whichever auth mode
you intend to use. `npx convex dev` keeps running: leave that terminal open
and run the command `npm run demo:key` printed from a second one. The first
terminal then deploys the backend by itself. Only a one-shot run
(`npx convex dev --once`, `npx convex deploy`) exits on the error and has to
be started again. This is needed once per deployment.

`npm run demo:key` writes the private key to gitignored `.env` (it is never
printed); only the public key set goes to Convex.

## Generate a demo JWT

Demo auth uses a custom JWT provider. Better Auth, Convex Auth and the public
screens need no token, but the Flutter app's Demo auth mode needs one,
generated from the key material above when launching Flutter. A token expires
after 24 hours:

```bash
npm run -s token
```

Do not commit `.env`, generated JWTs, or real deployment URLs, and do not
distribute a build that was given a token with `--dart-define`.

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
