// ignore_for_file: unused_local_variable
import 'package:dartvex/dartvex.dart';
import 'package:dartvex_auth_better/dartvex_auth_better.dart';

/// Example: Sign in with Better Auth and connect to Convex.
void main() async {
  // 1. Create the Better Auth HTTP client
  final authClient = BetterAuthClient(
    baseUrl: 'https://your-app.convex.cloud',
  );

  // 2. Create the Convex auth provider
  final authProvider = ConvexBetterAuthProvider(client: authClient);

  // 3. Set credentials
  authProvider.email = 'user@example.com';
  authProvider.password = 'secret123';

  // 4. Create an authenticated Convex client
  final convex = ConvexClient(
    'https://your-app.convex.cloud',
  );

  // 5. Sign in — the provider calls Better Auth's HTTP endpoints,
  //    retrieves a Convex JWT, and authenticates the WebSocket.
  final session = await authProvider.login(
    onIdToken: (token) {
      if (token != null) {
        convex.setAuth(token);
      }
    },
  );

  print('Signed in as ${session.email} (${session.userId})');

  // 6. Sign up a new user
  final newSession = await authProvider.signUp(
    name: 'Alice',
    email: 'alice@example.com',
    password: 'password123',
    onIdToken: (token) {
      if (token != null) {
        convex.setAuth(token);
      }
    },
  );

  // 7. Clean up
  await authProvider.logout();
  authClient.close();
  convex.dispose();
}
