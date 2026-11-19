import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  // App users of the Convex Auth mode. Convex Auth keeps credentials and
  // sessions in its own components and only stores this table's ids.
  users: defineTable({
    createdVia: v.string(),
  }),

  public_messages: defineTable({
    author: v.string(),
    text: v.string(),
  }),

  private_messages: defineTable({
    author: v.string(),
    text: v.string(),
    tokenIdentifier: v.string(),
    subject: v.string(),
    issuer: v.string(),
  }).index("by_token_identifier", ["tokenIdentifier"]),

  tasks: defineTable({
    title: v.string(),
    summary: v.union(v.string(), v.null()),
    status: v.string(),
    priority: v.string(),
    estimatePoints: v.number(),
    labels: v.array(v.string()),
    assignee: v.union(v.string(), v.null()),
    dueAt: v.union(v.number(), v.null()),
  }).index("by_status", ["status"]),

  // Backs the "Files" tab: each row pairs a Convex file-storage id with a
  // caption. The bytes live in built-in storage; rows here just track which
  // uploads to render (via dartvex_flutter's ConvexCachedImage).
  images: defineTable({
    storageId: v.id("_storage"),
    caption: v.string(),
  }),
});
