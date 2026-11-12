/// A call to a Convex Auth sign-in function: a mutation that returns the
/// shared sign-in envelope (`{status: "complete", tokens}` or
/// `{status: "error", userError}`).
///
/// Set it on `ConvexAuthSessionProvider.signIn`, then call
/// `authedClient.login()`. The named constructors cover the sign-in functions
/// of the built-in `@convex-dev/auth` methods, assuming the app re-exports
/// them from `convex/auth.ts` (the paths `auth:<name>`); pass `function` when
/// they live elsewhere. Use the default constructor for any other function
/// that returns the envelope.
class ConvexAuthSignIn {
  /// A call to the sign-in mutation [function] (a Convex function path such
  /// as `auth:signInWithUsernamePassword`) with [args].
  const ConvexAuthSignIn(this.function,
      [this.args = const <String, Object?>{}]);

  /// Signs in with `setupUsernamePassword`'s `signInWithUsernamePassword`.
  ConvexAuthSignIn.usernamePassword({
    required String username,
    required String password,
    String function = 'auth:signInWithUsernamePassword',
  }) : this(function, <String, Object?>{
          'username': username,
          'password': password,
        });

  /// Creates an account and signs in with `setupUsernamePassword`'s
  /// `signUpWithUsernamePassword`.
  ConvexAuthSignIn.usernamePasswordSignUp({
    required String username,
    required String password,
    String function = 'auth:signUpWithUsernamePassword',
  }) : this(function, <String, Object?>{
          'username': username,
          'password': password,
        });

  /// Signs in with `setupEmailPassword`'s `signInWithEmailPassword`.
  ConvexAuthSignIn.emailPassword({
    required String email,
    required String password,
    String function = 'auth:signInWithEmailPassword',
  }) : this(function, <String, Object?>{
          'email': email,
          'password': password,
        });

  /// Finishes an email sign-up with `completeSignUpWithEmailPassword`.
  ///
  /// [browserSecret] is returned by `signUpWithEmailPassword` (call it with
  /// `ConvexAuthHttpClient.mutation` or any Convex client); [emailCode] comes
  /// from the verification link.
  ConvexAuthSignIn.completeEmailPasswordSignUp({
    required String emailCode,
    required String browserSecret,
    String function = 'auth:completeSignUpWithEmailPassword',
  }) : this(function, <String, Object?>{
          'emailCode': emailCode,
          'browserSecret': browserSecret,
        });

  /// Sets a new password and signs in with `completePasswordRecovery`.
  ///
  /// [browserSecret] is returned by `startPasswordRecovery`; [emailCode]
  /// comes from the recovery link.
  ConvexAuthSignIn.completePasswordRecovery({
    required String emailCode,
    required String browserSecret,
    required String newPassword,
    String function = 'auth:completePasswordRecovery',
  }) : this(function, <String, Object?>{
          'emailCode': emailCode,
          'browserSecret': browserSecret,
          'newPassword': newPassword,
        });

  /// Signs in as a new anonymous user with `setupAnonymous`'s
  /// `signInAnonymously`.
  const ConvexAuthSignIn.anonymous({
    String function = 'auth:signInAnonymously',
  }) : this(function);

  /// The Convex function path of the sign-in mutation.
  final String function;

  /// The mutation arguments. May contain credentials.
  final Map<String, Object?> args;

  /// Omits [args], which may contain credentials.
  @override
  String toString() => 'ConvexAuthSignIn($function)';
}
