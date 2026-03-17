import { ConvexError, v } from "convex/values";

import { mutation, query } from "./_generated/server";

const taskValidator = v.object({
  _id: v.id("tasks"),
  _creationTime: v.number(),
  title: v.string(),
  summary: v.union(v.string(), v.null()),
  status: v.string(),
  priority: v.string(),
  estimatePoints: v.number(),
  labels: v.array(v.string()),
  assignee: v.union(v.string(), v.null()),
  dueAt: v.union(v.number(), v.null()),
});

export const listBoard = query({
  args: {},
  returns: v.array(taskValidator),
  handler: async (ctx) => {
    return await ctx.db.query("tasks").order("desc").collect();
  },
});

export const createTask = mutation({
  args: {
    title: v.string(),
    summary: v.union(v.string(), v.null()),
    priority: v.string(),
    estimatePoints: v.number(),
    labels: v.array(v.string()),
    assignee: v.union(v.string(), v.null()),
    dueAt: v.union(v.number(), v.null()),
  },
  returns: v.id("tasks"),
  handler: async (ctx, args) => {
    const title = args.title.trim();
    if (title.length === 0) {
      throw new ConvexError("Title is required");
    }

    const labels = [
      ...new Set(args.labels.map((label) => label.trim())),
    ].filter((label) => label.length > 0);

    return await ctx.db.insert("tasks", {
      title,
      summary:
        args.summary === null || args.summary.trim().length === 0
          ? null
          : args.summary.trim(),
      status: "backlog",
      priority: args.priority,
      estimatePoints: args.estimatePoints,
      labels,
      assignee:
        args.assignee === null || args.assignee.trim().length === 0
          ? null
          : args.assignee.trim(),
      dueAt: args.dueAt,
    });
  },
});

export const advanceTask = mutation({
  args: {
    taskId: v.id("tasks"),
  },
  returns: v.object({
    taskId: v.id("tasks"),
    status: v.string(),
  }),
  handler: async (ctx, args) => {
    const existing = await ctx.db.get(args.taskId);
    if (existing === null) {
      throw new ConvexError("Task not found");
    }

    const nextStatus =
      existing.status === "backlog"
        ? "in_progress"
        : existing.status === "in_progress"
          ? "done"
          : "backlog";

    await ctx.db.patch(args.taskId, {
      status: nextStatus,
    });

    return {
      taskId: args.taskId,
      status: nextStatus,
    };
  },
});

export const seedBoard = mutation({
  args: {},
  returns: v.number(),
  handler: async (ctx) => {
    const existing = await ctx.db.query("tasks").take(1);
    if (existing.length > 0) {
      return 0;
    }

    const now = Date.now();
    await Promise.all([
      ctx.db.insert("tasks", {
        title: "Polish the generated widgets",
        summary:
          "Tighten the bridge between convex_codegen and convex_flutter.",
        status: "backlog",
        priority: "high",
        estimatePoints: 5,
        labels: ["sdk", "widgets"],
        assignee: "Andre",
        dueAt: now + 2 * 24 * 60 * 60 * 1000,
      }),
      ctx.db.insert("tasks", {
        title: "Document the local-first roadmap",
        summary: "Capture sequencing decisions before convex_local starts.",
        status: "in_progress",
        priority: "medium",
        estimatePoints: 3,
        labels: ["docs", "architecture"],
        assignee: "Demo User",
        dueAt: now + 5 * 24 * 60 * 60 * 1000,
      }),
      ctx.db.insert("tasks", {
        title: "Ship the end-to-end demo",
        summary: null,
        status: "done",
        priority: "high",
        estimatePoints: 8,
        labels: ["demo", "convex", "flutter"],
        assignee: null,
        dueAt: null,
      }),
    ]);

    return 3;
  },
});

export const clearTasks = mutation({
  args: {},
  returns: v.number(),
  handler: async (ctx) => {
    const all = await ctx.db.query("tasks").collect();
    await Promise.all(all.map((doc) => ctx.db.delete(doc._id)));
    return all.length;
  },
});
