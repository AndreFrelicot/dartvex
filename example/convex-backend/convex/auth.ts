import { betterAuth } from "better-auth";
import { bearer } from "better-auth/plugins";
import { convex } from "@convex-dev/better-auth/plugins";
import { createClient, type GenericCtx } from "@convex-dev/better-auth";
import type { DataModel } from "./_generated/dataModel";
import { components } from "./_generated/api";
import authConfig from "./auth.config";

export const authComponent = createClient<DataModel>(components.betterAuth);

const localDevOriginPattern =
  /^https?:\/\/(?:localhost|127\.0\.0\.1)(?::\d+)?$/;

function splitOrigins(value: string | undefined) {
  return (value ?? "")
    .split(",")
    .map((origin) => origin.trim())
    .filter((origin) => origin.length > 0);
}

function betterAuthTrustedOrigins(request?: Request) {
  const requestOrigin = request?.headers.get("origin") ?? "";
  const localOrigin = localDevOriginPattern.test(requestOrigin)
    ? [requestOrigin]
    : [];

  return Array.from(
    new Set([
      process.env.CONVEX_SITE_URL,
      process.env.CONVEX_URL,
      ...splitOrigins(process.env.BETTER_AUTH_TRUSTED_ORIGINS),
      ...localOrigin,
    ])
  ).filter((origin): origin is string => typeof origin === "string");
}

export const createAuth = (ctx: GenericCtx<DataModel>) => {
  return betterAuth({
    database: authComponent.adapter(ctx),
    secret: process.env.BETTER_AUTH_SECRET,
    baseURL: process.env.CONVEX_SITE_URL,
    trustedOrigins: betterAuthTrustedOrigins,
    emailAndPassword: {
      enabled: true,
    },
    plugins: [bearer(), convex({ authConfig })],
  });
};
