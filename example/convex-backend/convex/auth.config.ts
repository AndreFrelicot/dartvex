import type { AuthConfig } from "convex/server";
import { getAuthConfigProvider } from "@convex-dev/better-auth/auth-config";
import { convexAuthProvider } from "@convex-dev/auth/server";

type AuthProvider = NonNullable<AuthConfig["providers"]>[number];

// Convex refuses an auth config that reads an unset environment variable, so
// DEMO_JWKS has to be set before the first deploy, whichever auth mode is
// used afterwards (see the README). The check below only guards an empty
// value.
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
    // Convex Auth v2 (access tokens signed with the deployment's own key).
    convexAuthProvider(),
  ],
} satisfies AuthConfig;
