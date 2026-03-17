import { ConvexError, v } from "convex/values";

import { action, query } from "./_generated/server";

const viewerValidator = v.union(
  v.object({
    tokenIdentifier: v.string(),
    subject: v.string(),
    issuer: v.string(),
    name: v.union(v.string(), v.null()),
    email: v.union(v.string(), v.null()),
  }),
  v.null(),
);

export const whoAmI = query({
  args: {},
  returns: viewerValidator,
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (identity === null) {
      return null;
    }

    return {
      tokenIdentifier: identity.tokenIdentifier,
      subject: identity.subject,
      issuer: identity.issuer,
      name: identity.name ?? null,
      email: identity.email ?? null,
    };
  },
});

export const requireAuthEcho = query({
  args: {
    message: v.string(),
  },
  returns: v.object({
    message: v.string(),
    tokenIdentifier: v.string(),
  }),
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (identity === null) {
      throw new ConvexError("Authentication required");
    }

    return {
      message: args.message,
      tokenIdentifier: identity.tokenIdentifier,
    };
  },
});

export const pingAction = action({
  args: {
    message: v.string(),
  },
  returns: v.object({
    echoedText: v.string(),
    receivedAt: v.number(),
    isAuthenticated: v.boolean(),
    viewerName: v.union(v.string(), v.null()),
  }),
  handler: async (ctx, args) => {
    const viewer = await ctx.auth.getUserIdentity();
    return {
      echoedText: args.message,
      receivedAt: Date.now(),
      isAuthenticated: viewer !== null,
      viewerName:
        viewer === null ? null : (viewer.name ?? viewer.email ?? null),
    };
  },
});
