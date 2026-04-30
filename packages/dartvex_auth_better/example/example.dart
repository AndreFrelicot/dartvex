import 'package:dartvex/dartvex.dart';
import 'package:dartvex_auth_better/dartvex_auth_better.dart';

/// Example: Sign in with Better Auth and connect to Convex.
Future<void> main() async {
  // 1. Create the Better Auth HTTP client
  final authClient = BetterAuthClient(
    baseUrl: 'https://your-app.convex.cloud',
  );

  // 2. Create the Convex auth provider
  final authProvider = ConvexBetterAuthProvider(client: authClient);

  // 3. Set credentials
  authProvider.email = 'user@example.com';
  authProvider.password = 'secret123';

  // 4. Create an authenticated Convex client wrapper
  final convex = ConvexClient(
    'https://your-app.convex.cloud',
  );
  final authedConvex = convex.withAuth(authProvider);

  // 5. Sign in — the provider calls Better Auth's HTTP endpoints and the
  //    wrapper forwards the Convex JWT to the WebSocket client.
  final session = await authedConvex.login();

  print('Signed in as ${session.email} (${session.userId})');

  // 6. Sign up a new user directly through the HTTP client when needed.
  final newSession = await authClient.signUp(
    name: 'Alice',
    email: 'alice@example.com',
    password: 'password123',
  );
  await authClient.signOut(sessionToken: newSession.sessionToken);

  // 7. Clean up
  await authedConvex.logout();
  authClient.close();
  authedConvex.dispose();
}
