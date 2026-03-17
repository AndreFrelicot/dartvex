import type { AuthConfig } from "convex/server";
import { getAuthConfigProvider } from "@convex-dev/better-auth/auth-config";

export default {
  providers: [
    // Demo app custom JWT (ES256 self-signed for demo auth provider).
    {
      type: "customJwt",
      issuer: "https://demo.convex-flutter-sdk.local",
      applicationID: "convex-flutter-demo",
      algorithm: "ES256",
      jwks: "data:application/json;base64,eyJrZXlzIjpbeyJrdHkiOiJFQyIsIngiOiIyMm1ZTVpGcEM0dHNid1ZmdXhpSmFiTUNuVWVYM1lnQ09LY0poVGJfSmlJIiwieSI6IjZYUXpFMHptSkgwT3dYZlVLbmlSbzRjTTRVTVJMY2tiVEMwazczcEdHdlEiLCJjcnYiOiJQLTI1NiIsInVzZSI6InNpZyIsImFsZyI6IkVTMjU2Iiwia2lkIjoiZGVtby1rZXktMSJ9XX0=",
    },
    // Clerk (hosted auth, RS256 JWTs).
    // Set CLERK_ISSUER_URL via: npx convex env set CLERK_ISSUER_URL https://xxx.clerk.accounts.dev
    ...(process.env.CLERK_ISSUER_URL
      ? [{ domain: process.env.CLERK_ISSUER_URL, applicationID: "convex" }]
      : []),
    // Better Auth (self-hosted in Convex, RS256 JWTs).
    getAuthConfigProvider(),
  ],
} satisfies AuthConfig;
