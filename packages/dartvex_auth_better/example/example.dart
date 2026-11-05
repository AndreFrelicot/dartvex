import 'package:dartvex/dartvex.dart';
import 'package:dartvex_auth_better/dartvex_auth_better.dart';

/// Example: Sign in with Better Auth and connect to Convex.
Future<void> main() async {
  // 1. Create the Better Auth HTTP client. For local or self-hosted
  //    deployments, also pass `siteUrl` (the deployment's CONVEX_SITE_URL).
  final authClient = BetterAuthClient(
    baseUrl: 'https://your-deployment.convex.cloud',
  );

  // 2. Create the Convex auth provider and the authenticated client wrapper.
  final authProvider = ConvexBetterAuthProvider(client: authClient);
  final convex = ConvexClient(
    'https://your-deployment.convex.cloud',
  );
  final authedConvex = convex.withAuth(authProvider);

  // 3. Sign in — the provider calls Better Auth's HTTP endpoints and the
  //    wrapper forwards the Convex JWT to the WebSocket client.
  authProvider.email = 'user@example.com';
  authProvider.password = 'secret123';
  try {
    final session = await authedConvex.login();
    print('Signed in as ${session.email} (${session.userId})');
  } on BetterAuthException catch (error) {
    // error.code is Better Auth's error code, e.g. INVALID_EMAIL_OR_PASSWORD.
    print('Sign-in failed: ${error.code ?? error.message}');
  }

  // 4. Sign out through the wrapper so the Convex client is signed out too.
  await authedConvex.logout();

  // 5. Sign up a new user, then authenticate the Convex client. login()
  //    reuses the session created by signUp().
  try {
    await authProvider.signUp(
      name: 'Alice',
      email: 'alice@example.com',
      password: 'password123',
    );
    await authedConvex.login();
  } on BetterAuthEmailVerificationRequiredException {
    print('Check your inbox to verify your email, then sign in.');
  }

  // 6. Clean up
  await authedConvex.logout();
  authClient.close();
  authedConvex.dispose();
}
