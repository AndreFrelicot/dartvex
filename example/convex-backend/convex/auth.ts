import { betterAuth } from "better-auth";
import { convex } from "@convex-dev/better-auth/plugins";
import { createClient, type GenericCtx } from "@convex-dev/better-auth";
import type { DataModel } from "./_generated/dataModel";
import { components } from "./_generated/api";
import authConfig from "./auth.config";

export const authComponent = createClient<DataModel>(components.betterAuth);

export const createAuth = (ctx: GenericCtx<DataModel>) => {
  return betterAuth({
    database: authComponent.adapter(ctx),
    secret: process.env.BETTER_AUTH_SECRET,
    baseURL: process.env.CONVEX_SITE_URL,
    trustedOrigins: ["http://localhost:*", "http://127.0.0.1:*"],
    emailAndPassword: {
      enabled: true,
    },
    plugins: [convex({ authConfig })],
  });
};
