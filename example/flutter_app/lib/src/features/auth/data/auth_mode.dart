/// Auth mode for the demo app.
///
/// This is demo-app configuration only — not part of the SDK.
enum AuthMode {
  /// Deterministic in-memory auth provider (no external service).
  demo,

  /// Better Auth (self-hosted in Convex) using dartvex_auth_better.
  betterAuth,

  /// Convex Auth v2 (`@convex-dev/auth`) using dartvex_auth2_convex.
  convexAuth,
}
