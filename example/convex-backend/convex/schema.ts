import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
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
});
