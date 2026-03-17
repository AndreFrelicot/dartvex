abstract class AuthProvider<TUser> {
  Future<TUser> login({required void Function(String? token) onIdToken});

  Future<TUser> loginFromCache({
    required void Function(String? token) onIdToken,
  });

  Future<void> logout();

  String extractIdToken(TUser authResult);
}
