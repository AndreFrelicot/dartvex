import { getAuthUserId } from "@convex-dev/auth/server";
import type { UserIdentity } from "convex/server";
import { ConvexError } from "convex/values";

import type { MutationCtx, QueryCtx } from "./_generated/server";

// The issuer `convexAuthProvider()` registers in auth.config.ts: Convex Auth
// access tokens are signed by the deployment for the `auth` component.
function isConvexAuthIdentity(identity: UserIdentity): boolean {
  return identity.issuer === `${process.env.CONVEX_CLOUD_URL}/components/auth`;
}

/**
 * The signed-in caller and the key that scopes their private data.
 *
 * The demo JWT and Better Auth tokens name a user, so `tokenIdentifier` is
 * already stable across sign-ins. A Convex Auth token names a *session*
 * (`subject` is the session id): keying data on it would hide a user's rows
 * every time they sign in again. `getAuthUserId` resolves the session to its
 * user, and returns null as soon as the session is revoked, even while the
 * short-lived token is still valid.
 */
export async function requireOwner(
  ctx: QueryCtx | MutationCtx,
): Promise<{ identity: UserIdentity; ownerKey: string }> {
  const identity = await ctx.auth.getUserIdentity();
  if (identity === null) {
    throw new ConvexError("Authentication required");
  }
  if (!isConvexAuthIdentity(identity)) {
    return { identity, ownerKey: identity.tokenIdentifier };
  }
  const userId = await getAuthUserId(ctx);
  if (userId === null) {
    throw new ConvexError("Authentication required");
  }
  return { identity, ownerKey: `${identity.issuer}|user:${userId}` };
}
