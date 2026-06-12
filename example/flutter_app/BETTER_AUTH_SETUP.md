# Better Auth Setup

Better Auth runs as a self-hosted Convex component — no external auth service needed.

## Backend Setup

1. **Install dependencies** in `example/convex-backend/`:

   Requires Node.js 20.19.0 or newer. Use npm; the backend commits an npm
   `package-lock.json`.

   ```bash
   cd example/convex-backend
   npm install better-auth@1.6.17 @convex-dev/better-auth@0.12.3
   ```

2. **Set the secret** in your Convex deployment:

   ```bash
   npx convex env set BETTER_AUTH_SECRET=$(openssl rand -base64 32)
   ```

3. **Allow hosted web origins when needed**:

   ```bash
   npx convex env set BETTER_AUTH_TRUSTED_ORIGINS=https://your-web-demo.example
   ```

   Flutter web on `localhost` or `127.0.0.1` is accepted automatically.

4. **Deploy** the backend:

   ```bash
   npx convex dev    # local development
   # or
   npx convex deploy # production
   ```

   The backend already includes the required files:
   - `convex/convex.config.ts` — registers the Better Auth component
   - `convex/auth.ts` — Better Auth instance with email/password enabled
   - `convex/http.ts` — mounts HTTP routes at `/api/auth/*`
   - `convex/auth.config.ts` — JWT verification config (both Demo + Better Auth)

## Flutter App

Run the demo app with your Convex deployment URL:

```bash
cd example/flutter_app
flutter run --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud
```

Select **Better Auth** in the Auth tab's mode selector to use the self-hosted auth flow.

## How It Works

1. The Flutter app calls Better Auth HTTP endpoints on your Convex deployment (`.convex.site`)
2. Sign-up/sign-in returns a session token via the `set-auth-token` header
3. The session token is exchanged for a Convex JWT via `/api/auth/convex/token`
4. The JWT authenticates the Convex WebSocket connection

## Package Structure

The `dartvex_auth_better` package (`packages/dartvex_auth_better/`) provides:

- `BetterAuthClient` — HTTP client for Better Auth endpoints
- `ConvexBetterAuthProvider` — implements `AuthProvider<BetterAuthSession>` for use with `ConvexClient.withAuth()`
- `BetterAuthSession` — session model (JWT, userId, email, name)
