// Convex Auth v2 (`@convex-dev/auth`) for the "Convex Auth" mode of the
// Flutter demo, driven from Dart by `dartvex_auth2_convex`.
//
// These functions usually live in `convex/auth.ts` (paths `auth:<name>`, the
// defaults of the Dart package). That file already holds Better Auth here, so
// they are exported from this module and the Flutter app passes the
// `convexAuth:<name>` paths explicitly.
import { setupConvexAuth } from "@convex-dev/auth/server";
import { setupUsernamePassword } from "@convex-dev/auth/methods/username-password/server";

import { components, internal } from "./_generated/api";

const auth = setupConvexAuth({ component: components.auth });

// The session functions the client calls over HTTP: `refreshSession` trades
// the refresh token for a new session, `signOut` revokes it.
export const { signOut, refreshSession, isAuthenticated } = auth;

// Username + password sign-in. Both return the sign-in envelope:
// `{status: "complete", tokens}` or `{status: "error", userError}`.
export const { signUpWithUsernamePassword, signInWithUsernamePassword } =
  setupUsernamePassword(auth, {
    component: components.authPassword,
    usernameComponent: components.authUsername,
  }).attachUserCallbacks({ createUser: internal.users.createUserPassword });
