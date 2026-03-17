# Better Auth Setup

Better Auth runs as a self-hosted Convex component — no external auth service needed.

## Backend Setup

1. **Install dependencies** in `example/convex-backend/`:

   ```bash
   cd example/convex-backend
   npm install better-auth@1.5.3 @convex-dev/better-auth --legacy-peer-deps
   ```

2. **Set the secret** in your Convex deployment:

   ```bash
   npx convex env set BETTER_AUTH_SECRET=$(openssl rand -base64 32)
   ```

3. **Deploy** the backend:

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
flutter run --dart-define=CONVEX_DEMO_URL=https://your-app.convex.cloud
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
