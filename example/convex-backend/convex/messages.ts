import { ConvexError, v } from "convex/values";

import { mutation, query } from "./_generated/server";

const publicMessageValidator = v.object({
  _id: v.id("public_messages"),
  _creationTime: v.number(),
  author: v.string(),
  text: v.string(),
});

const privateMessageValidator = v.object({
  _id: v.id("private_messages"),
  _creationTime: v.number(),
  author: v.string(),
  text: v.string(),
  tokenIdentifier: v.string(),
});

export const listPublic = query({
  args: {},
  returns: v.array(publicMessageValidator),
  handler: async (ctx) => {
    return await ctx.db.query("public_messages").order("desc").collect();
  },
});

export const sendPublic = mutation({
  args: {
    author: v.string(),
    text: v.string(),
  },
  returns: v.id("public_messages"),
  handler: async (ctx, args) => {
    return await ctx.db.insert("public_messages", {
      author: args.author,
      text: args.text,
    });
  },
});

export const listPrivate = query({
  args: {},
  returns: v.array(privateMessageValidator),
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (identity === null) {
      throw new ConvexError("Authentication required");
    }

    const messages = await ctx.db
      .query("private_messages")
      .withIndex("by_token_identifier", (q) =>
        q.eq("tokenIdentifier", identity.tokenIdentifier),
      )
      .order("desc")
      .collect();

    return messages.map((message) => ({
      _id: message._id,
      _creationTime: message._creationTime,
      author: message.author,
      text: message.text,
      tokenIdentifier: message.tokenIdentifier,
    }));
  },
});

export const sendPrivate = mutation({
  args: {
    text: v.string(),
  },
  returns: v.id("private_messages"),
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (identity === null) {
      throw new ConvexError("Authentication required");
    }

    return await ctx.db.insert("private_messages", {
      author: identity.name ?? identity.email ?? identity.subject,
      text: args.text,
      tokenIdentifier: identity.tokenIdentifier,
      subject: identity.subject,
      issuer: identity.issuer,
    });
  },
});

export const clearPublicMessages = mutation({
  args: {},
  returns: v.number(),
  handler: async (ctx) => {
    const all = await ctx.db.query("public_messages").collect();
    await Promise.all(all.map((doc) => ctx.db.delete(doc._id)));
    return all.length;
  },
});
