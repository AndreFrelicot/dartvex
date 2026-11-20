import { getAuthUserId } from "@convex-dev/auth/server";
import { v } from "convex/values";

import { internalMutation, query } from "./_generated/server";

// Called by Convex Auth when a username/password account is created. The app
// owns its users table; the auth components only know the returned id.
export const createUserPassword = internalMutation({
  args: {
    method: v.object({
      name: v.literal("usernamePassword"),
      profile: v.object({}),
    }),
  },
  returns: v.id("users"),
  handler: async (ctx) => {
    return await ctx.db.insert("users", { createdVia: "usernamePassword" });
  },
});

// The Convex Auth user the caller is signed in as, or null (signed out, or
// signed in through another provider). A Convex Auth access token names a
// session, not a user: `getAuthUserId` looks the session up, so this also
// returns null as soon as the session is revoked.
export const viewer = query({
  args: {},
  returns: v.union(
    v.object({
      userId: v.id("users"),
      createdVia: v.string(),
      _creationTime: v.number(),
    }),
    v.null(),
  ),
  handler: async (ctx) => {
    const userId = await getAuthUserId(ctx);
    if (userId === null) {
      return null;
    }
    const user = await ctx.db.get(userId);
    if (user === null) {
      return null;
    }
    return {
      userId: user._id,
      createdVia: user.createdVia,
      _creationTime: user._creationTime,
    };
  },
});
