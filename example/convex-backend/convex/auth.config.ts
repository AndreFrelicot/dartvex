import type { AuthConfig } from "convex/server";
import { getAuthConfigProvider } from "@convex-dev/better-auth/auth-config";

type AuthProvider = NonNullable<AuthConfig["providers"]>[number];

const demoJwks = process.env.DEMO_JWKS;
const demoJwtProvider = demoJwks
  ? ({
      type: "customJwt",
      issuer: "https://demo.convex-flutter-sdk.local",
      applicationID: "convex-flutter-demo",
      algorithm: "ES256",
      jwks: demoJwks,
    } satisfies AuthProvider)
  : null;

export default {
  providers: [
    ...(demoJwtProvider ? [demoJwtProvider] : []),
    // Better Auth (self-hosted in Convex, RS256 JWTs).
    getAuthConfigProvider(),
  ],
} satisfies AuthConfig;
