import 'package:dartvex/dartvex.dart';
import 'package:dartvex_auth_convex/dartvex_auth_convex.dart';

/// Example: sign in with Convex Auth (`@convex-dev/auth` v2) and connect to
/// Convex. The backend re-exports the core and username/password functions
/// from `convex/auth.ts`.
Future<void> main() async {
  const deploymentUrl = 'https://your-deployment.convex.cloud';

  // 1. The HTTP client refreshes and revokes sessions outside the WebSocket.
  final authClient = ConvexAuthHttpClient(deploymentUrl: deploymentUrl);

  // 2. The provider owns the session. Persist every change: the refresh token
  //    rotates on each refresh. Pass the saved session back as
  //    `initialSession` on the next start.
  ConvexAuthSession? savedSession; // e.g. from flutter_secure_storage
  final provider = ConvexAuthSessionProvider(
    client: authClient,
    initialSession: savedSession,
    onSessionChanged: (session) {
      // Write session?.toJson() to secure storage, or delete it when null.
      savedSession = session;
    },
  );

  // disposeClient: true lets the wrapper close the ConvexClient on dispose.
  final convex = ConvexClient(deploymentUrl);
  final authedConvex = convex.withAuth(provider, disposeClient: true);

  // 3. Restore a persisted session, or sign in.
  try {
    await authedConvex.loginFromCache();
  } on ConvexAuthSessionEndedException {
    provider.signIn = ConvexAuthSignIn.usernamePassword(
      username: 'alice',
      password: 'correct horse battery staple',
    );
    try {
      final session = await authedConvex.login();
      print('Signed in as ${session.userId}');
    } on ConvexAuthSignInException catch (error) {
      // error.code is the method's userError code, e.g. INVALID_CREDENTIALS.
      print('Sign-in failed: ${error.code}');
    }
  }

  // 4. Sign out through the wrapper so the Convex client is signed out too.
  await authedConvex.logout();
  authClient.close();
  authedConvex.dispose();
}
