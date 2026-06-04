import { ConvexError, v } from "convex/values";
import { paginationOptsValidator } from "convex/server";

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

// Reactive, gapless pagination over the public feed. Used by the Showcase
// `PaginatedQueryBuilder` demo. Returns a standard Convex PaginationResult.
export const paginatePublic = query({
  args: { paginationOpts: paginationOptsValidator },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("public_messages")
      .order("desc")
      .paginate(args.paginationOpts);
  },
});

// Total number of public messages. Pairs with the cursor pagination so the
// Showcase can render a "showing N of TOTAL / page X of Y" indicator — cursor
// pagination has no built-in total. Counts all rows (fine for the demo; a large
// table would use an aggregated counter instead).
export const countPublic = query({
  args: {},
  returns: v.number(),
  handler: async (ctx) => {
    const all = await ctx.db.query("public_messages").collect();
    return all.length;
  },
});

// Idempotent demo seed: tops the public feed up to `target` rows so the
// pagination demo always has several pages. Returns how many were inserted.
export const seedPublic = mutation({
  args: {},
  returns: v.number(),
  handler: async (ctx) => {
    const target = 42;
    const existing = await ctx.db.query("public_messages").collect();
    if (existing.length >= target) {
      return 0;
    }

    const authors = ["Ada", "Linus", "Grace", "Margaret", "Dennis", "Barbara"];
    const snippets = [
      "Shipping the realtime sync demo today.",
      "Optimistic updates feel instant on mobile.",
      "Reactive pagination keeps the feed gapless.",
      "Reconnect after airplane mode just works.",
      "Auth refresh stays invisible to the user.",
      "Convex transitions land in a single frame.",
      "Pure Dart client, no native bridge.",
      "Connection status surfaces inflight requests.",
    ];

    const toInsert = target - existing.length;
    for (let i = 0; i < toInsert; i += 1) {
      const n = existing.length + i + 1;
      await ctx.db.insert("public_messages", {
        author: authors[i % authors.length],
        text: `#${n} ${snippets[i % snippets.length]}`,
      });
    }
    return toInsert;
  },
});

// Always rejects. The Showcase routes "fail the next send" here so the optimistic
// overlay is observed rolling back when the server rejects the mutation.
export const failingSend = mutation({
  args: {
    author: v.string(),
    text: v.string(),
  },
  returns: v.null(),
  handler: async () => {
    throw new ConvexError(
      "Simulated failure: this mutation always rejects so the optimistic " +
        "update rolls back.",
    );
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
