import { v } from "convex/values";

import { mutation, query } from "./_generated/server";

// Convex built-in file storage, exposed to the Flutter "Files" demo.
//
// Upload is a two-step handshake (mirrored by dartvex's ConvexStorage):
//   1. the client calls `generateUploadUrl` for a short-lived signed URL,
//   2. the client POSTs the bytes to that URL and gets back a `storageId`,
//   3. the client records the `storageId` via `add` so it shows up in `list`.
// Images are rendered with `getUrl`, which resolves a storageId to a signed
// download URL (a query, so dartvex's ConvexCachedImage uses the default
// query path — keep `useAction: false` on the widget side).

export const generateUploadUrl = mutation({
  args: {},
  returns: v.string(),
  handler: async (ctx) => {
    return await ctx.storage.generateUploadUrl();
  },
});

export const getUrl = query({
  args: { storageId: v.id("_storage") },
  returns: v.union(v.string(), v.null()),
  handler: async (ctx, args) => {
    return await ctx.storage.getUrl(args.storageId);
  },
});

export const list = query({
  args: {},
  returns: v.array(
    v.object({
      _id: v.id("images"),
      _creationTime: v.number(),
      storageId: v.id("_storage"),
      caption: v.string(),
    }),
  ),
  handler: async (ctx) => {
    return await ctx.db.query("images").order("desc").collect();
  },
});

export const add = mutation({
  args: {
    storageId: v.id("_storage"),
    caption: v.string(),
  },
  returns: v.id("images"),
  handler: async (ctx, args) => {
    return await ctx.db.insert("images", {
      storageId: args.storageId,
      caption: args.caption,
    });
  },
});

// Removes every image row and its underlying stored blob. Returns how many rows
// were cleared so the demo can report it.
export const clear = mutation({
  args: {},
  returns: v.number(),
  handler: async (ctx) => {
    const all = await ctx.db.query("images").collect();
    await Promise.all(
      all.map(async (doc) => {
        await ctx.storage.delete(doc.storageId);
        await ctx.db.delete(doc._id);
      }),
    );
    return all.length;
  },
});
