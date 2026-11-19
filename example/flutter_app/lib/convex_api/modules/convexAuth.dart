// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: type=lint, unused_element, unused_import, unused_local_variable

import '../runtime.dart';
import '../schema.dart';
import 'package:dartvex/dartvex.dart';

class ConvexAuthApi {
  const ConvexAuthApi(this._client);

  final ConvexFunctionCaller _client;

  Future<bool> isAuthenticated() async {
    final raw$ = await _client.query(
      'convexAuth:isAuthenticated',
      const <String, dynamic>{},
    );
    return expectBool(raw$, label: 'IsAuthenticatedResult');
  }

  TypedConvexSubscription<bool> isAuthenticatedSubscribe() {
    final subscription$ = _client.subscribe(
      'convexAuth:isAuthenticated',
      const <String, dynamic>{},
    );
    return TypedConvexSubscription<bool>(
      subscription$,
      subscription$.stream.map(
        (event$) => typedQueryResult<bool>(
          event$,
          (raw$) => expectBool(raw$, label: 'IsAuthenticatedResult'),
          'convexAuth:isAuthenticated',
        ),
      ),
    );
  }

  Future<RefreshSessionResult> refreshSession({
    required String refreshToken,
    OptimisticUpdate? optimisticUpdate,
  }) async {
    final raw$ = await _client.mutate(
      'convexAuth:refreshSession',
      _encodeRefreshSessionArgs((refreshToken: refreshToken)),
      optimisticUpdate,
    );
    return _decodeRefreshSessionResult(raw$);
  }

  Future<SignInWithUsernamePasswordResult> signInWithUsernamePassword({
    required String password,
    required String username,
    OptimisticUpdate? optimisticUpdate,
  }) async {
    final raw$ = await _client.mutate(
      'convexAuth:signInWithUsernamePassword',
      _encodeSignInWithUsernamePasswordArgs((
        password: password,
        username: username,
      )),
      optimisticUpdate,
    );
    return _decodeSignInWithUsernamePasswordResult(raw$);
  }

  Future<Null> signOut({
    required String refreshToken,
    OptimisticUpdate? optimisticUpdate,
  }) async {
    await _client.mutate(
      'convexAuth:signOut',
      _encodeSignOutArgs((refreshToken: refreshToken)),
      optimisticUpdate,
    );
    return null;
  }

  Future<SignUpWithUsernamePasswordResult> signUpWithUsernamePassword({
    required String password,
    required String username,
    OptimisticUpdate? optimisticUpdate,
  }) async {
    final raw$ = await _client.mutate(
      'convexAuth:signUpWithUsernamePassword',
      _encodeSignUpWithUsernamePasswordArgs((
        password: password,
        username: username,
      )),
      optimisticUpdate,
    );
    return _decodeSignUpWithUsernamePasswordResult(raw$);
  }
}

typedef RefreshSessionResult1Tokens = ({
  String accessToken,
  String refreshToken,
  double refreshTokenExpiresAt,
  String userId,
});

Map<String, dynamic> _encodeRefreshSessionResult1Tokens(
  RefreshSessionResult1Tokens value$,
) {
  final (
    accessToken: accessToken,
    refreshToken: refreshToken,
    refreshTokenExpiresAt: refreshTokenExpiresAt,
    userId: userId,
  ) = value$;
  return <String, dynamic>{
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'refreshTokenExpiresAt': refreshTokenExpiresAt,
    'userId': userId,
  };
}

RefreshSessionResult1Tokens _decodeRefreshSessionResult1Tokens(dynamic raw) {
  final map = expectMap(raw, label: 'RefreshSessionResult1Tokens');
  if (!map.containsKey('accessToken')) {
    throw FormatException(
      'Missing required field "accessToken" for RefreshSessionResult1Tokens',
    );
  }
  if (!map.containsKey('refreshToken')) {
    throw FormatException(
      'Missing required field "refreshToken" for RefreshSessionResult1Tokens',
    );
  }
  if (!map.containsKey('refreshTokenExpiresAt')) {
    throw FormatException(
      'Missing required field "refreshTokenExpiresAt" for RefreshSessionResult1Tokens',
    );
  }
  if (!map.containsKey('userId')) {
    throw FormatException(
      'Missing required field "userId" for RefreshSessionResult1Tokens',
    );
  }
  return (
    accessToken: expectString(
      map['accessToken'],
      label: 'RefreshSessionResult1TokensAccessToken',
    ),
    refreshToken: expectString(
      map['refreshToken'],
      label: 'RefreshSessionResult1TokensRefreshToken',
    ),
    refreshTokenExpiresAt: expectDouble(
      map['refreshTokenExpiresAt'],
      label: 'RefreshSessionResult1TokensRefreshTokenExpiresAt',
    ),
    userId: expectString(
      map['userId'],
      label: 'RefreshSessionResult1TokensUserId',
    ),
  );
}

typedef RefreshSessionResult1 = ({
  String kind,
  RefreshSessionResult1Tokens tokens,
});

Map<String, dynamic> _encodeRefreshSessionResult1(
  RefreshSessionResult1 value$,
) {
  final (kind: kind, tokens: tokens) = value$;
  return <String, dynamic>{
    'kind': kind,
    'tokens': _encodeRefreshSessionResult1Tokens(tokens),
  };
}

RefreshSessionResult1 _decodeRefreshSessionResult1(dynamic raw) {
  final map = expectMap(raw, label: 'RefreshSessionResult1');
  if (!map.containsKey('kind')) {
    throw FormatException(
      'Missing required field "kind" for RefreshSessionResult1',
    );
  }
  if (!map.containsKey('tokens')) {
    throw FormatException(
      'Missing required field "tokens" for RefreshSessionResult1',
    );
  }
  return (
    kind: expectLiteral<String>(
      map['kind'],
      'rotated',
      label: 'RefreshSessionResult1Kind',
    ),
    tokens: _decodeRefreshSessionResult1Tokens(map['tokens']),
  );
}

typedef RefreshSessionResult2 = ({String kind});

Map<String, dynamic> _encodeRefreshSessionResult2(
  RefreshSessionResult2 value$,
) {
  final (kind: kind) = value$;
  return <String, dynamic>{'kind': kind};
}

RefreshSessionResult2 _decodeRefreshSessionResult2(dynamic raw) {
  final map = expectMap(raw, label: 'RefreshSessionResult2');
  if (!map.containsKey('kind')) {
    throw FormatException(
      'Missing required field "kind" for RefreshSessionResult2',
    );
  }
  return (
    kind: expectLiteral<String>(
      map['kind'],
      'noSession',
      label: 'RefreshSessionResult2Kind',
    ),
  );
}

sealed class RefreshSessionResult {
  const RefreshSessionResult();
}

class RefreshSessionResult1Value extends RefreshSessionResult {
  const RefreshSessionResult1Value(this.value);
  final RefreshSessionResult1 value;
}

class RefreshSessionResult2Value extends RefreshSessionResult {
  const RefreshSessionResult2Value(this.value);
  final RefreshSessionResult2 value;
}

dynamic _encodeRefreshSessionResult(RefreshSessionResult value) {
  switch (value) {
    case RefreshSessionResult1Value(value: final inner):
      return _encodeRefreshSessionResult1(inner);
    case RefreshSessionResult2Value(value: final inner):
      return _encodeRefreshSessionResult2(inner);
  }
}

RefreshSessionResult _decodeRefreshSessionResult(dynamic raw) {
  final errors = <String>[];
  try {
    return RefreshSessionResult1Value(_decodeRefreshSessionResult1(raw));
  } catch (e) {
    errors.add('RefreshSessionResult1Value: $e');
  }
  try {
    return RefreshSessionResult2Value(_decodeRefreshSessionResult2(raw));
  } catch (e) {
    errors.add('RefreshSessionResult2Value: $e');
  }
  throw FormatException(
    'Expected RefreshSessionResult but received ${describeType(raw)}.\n'
    'Tried: ${errors.join(", ")}',
  );
}

typedef RefreshSessionArgs = ({String refreshToken});

Map<String, dynamic> _encodeRefreshSessionArgs(RefreshSessionArgs value$) {
  final (refreshToken: refreshToken) = value$;
  return <String, dynamic>{'refreshToken': refreshToken};
}

RefreshSessionArgs _decodeRefreshSessionArgs(dynamic raw) {
  final map = expectMap(raw, label: 'RefreshSessionArgs');
  if (!map.containsKey('refreshToken')) {
    throw FormatException(
      'Missing required field "refreshToken" for RefreshSessionArgs',
    );
  }
  return (
    refreshToken: expectString(
      map['refreshToken'],
      label: 'RefreshSessionArgsRefreshToken',
    ),
  );
}

typedef SignInWithUsernamePasswordResult1Tokens = ({
  String accessToken,
  String refreshToken,
  double refreshTokenExpiresAt,
  String userId,
});

Map<String, dynamic> _encodeSignInWithUsernamePasswordResult1Tokens(
  SignInWithUsernamePasswordResult1Tokens value$,
) {
  final (
    accessToken: accessToken,
    refreshToken: refreshToken,
    refreshTokenExpiresAt: refreshTokenExpiresAt,
    userId: userId,
  ) = value$;
  return <String, dynamic>{
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'refreshTokenExpiresAt': refreshTokenExpiresAt,
    'userId': userId,
  };
}

SignInWithUsernamePasswordResult1Tokens
_decodeSignInWithUsernamePasswordResult1Tokens(dynamic raw) {
  final map = expectMap(raw, label: 'SignInWithUsernamePasswordResult1Tokens');
  if (!map.containsKey('accessToken')) {
    throw FormatException(
      'Missing required field "accessToken" for SignInWithUsernamePasswordResult1Tokens',
    );
  }
  if (!map.containsKey('refreshToken')) {
    throw FormatException(
      'Missing required field "refreshToken" for SignInWithUsernamePasswordResult1Tokens',
    );
  }
  if (!map.containsKey('refreshTokenExpiresAt')) {
    throw FormatException(
      'Missing required field "refreshTokenExpiresAt" for SignInWithUsernamePasswordResult1Tokens',
    );
  }
  if (!map.containsKey('userId')) {
    throw FormatException(
      'Missing required field "userId" for SignInWithUsernamePasswordResult1Tokens',
    );
  }
  return (
    accessToken: expectString(
      map['accessToken'],
      label: 'SignInWithUsernamePasswordResult1TokensAccessToken',
    ),
    refreshToken: expectString(
      map['refreshToken'],
      label: 'SignInWithUsernamePasswordResult1TokensRefreshToken',
    ),
    refreshTokenExpiresAt: expectDouble(
      map['refreshTokenExpiresAt'],
      label: 'SignInWithUsernamePasswordResult1TokensRefreshTokenExpiresAt',
    ),
    userId: expectString(
      map['userId'],
      label: 'SignInWithUsernamePasswordResult1TokensUserId',
    ),
  );
}

typedef SignInWithUsernamePasswordResult1 = ({
  String status,
  SignInWithUsernamePasswordResult1Tokens tokens,
});

Map<String, dynamic> _encodeSignInWithUsernamePasswordResult1(
  SignInWithUsernamePasswordResult1 value$,
) {
  final (status: status, tokens: tokens) = value$;
  return <String, dynamic>{
    'status': status,
    'tokens': _encodeSignInWithUsernamePasswordResult1Tokens(tokens),
  };
}

SignInWithUsernamePasswordResult1 _decodeSignInWithUsernamePasswordResult1(
  dynamic raw,
) {
  final map = expectMap(raw, label: 'SignInWithUsernamePasswordResult1');
  if (!map.containsKey('status')) {
    throw FormatException(
      'Missing required field "status" for SignInWithUsernamePasswordResult1',
    );
  }
  if (!map.containsKey('tokens')) {
    throw FormatException(
      'Missing required field "tokens" for SignInWithUsernamePasswordResult1',
    );
  }
  return (
    status: expectLiteral<String>(
      map['status'],
      'complete',
      label: 'SignInWithUsernamePasswordResult1Status',
    ),
    tokens: _decodeSignInWithUsernamePasswordResult1Tokens(map['tokens']),
  );
}

typedef SignInWithUsernamePasswordResult2UserError1 = ({
  String error,
  double minimumLength,
});

Map<String, dynamic> _encodeSignInWithUsernamePasswordResult2UserError1(
  SignInWithUsernamePasswordResult2UserError1 value$,
) {
  final (error: error, minimumLength: minimumLength) = value$;
  return <String, dynamic>{'error': error, 'minimumLength': minimumLength};
}

SignInWithUsernamePasswordResult2UserError1
_decodeSignInWithUsernamePasswordResult2UserError1(dynamic raw) {
  final map = expectMap(
    raw,
    label: 'SignInWithUsernamePasswordResult2UserError1',
  );
  if (!map.containsKey('error')) {
    throw FormatException(
      'Missing required field "error" for SignInWithUsernamePasswordResult2UserError1',
    );
  }
  if (!map.containsKey('minimumLength')) {
    throw FormatException(
      'Missing required field "minimumLength" for SignInWithUsernamePasswordResult2UserError1',
    );
  }
  return (
    error: expectLiteral<String>(
      map['error'],
      'PASSWORD_TOO_SHORT',
      label: 'SignInWithUsernamePasswordResult2UserError1Error',
    ),
    minimumLength: expectDouble(
      map['minimumLength'],
      label: 'SignInWithUsernamePasswordResult2UserError1MinimumLength',
    ),
  );
}

typedef SignInWithUsernamePasswordResult2UserError2 = ({
  String error,
  double maximumLength,
});

Map<String, dynamic> _encodeSignInWithUsernamePasswordResult2UserError2(
  SignInWithUsernamePasswordResult2UserError2 value$,
) {
  final (error: error, maximumLength: maximumLength) = value$;
  return <String, dynamic>{'error': error, 'maximumLength': maximumLength};
}

SignInWithUsernamePasswordResult2UserError2
_decodeSignInWithUsernamePasswordResult2UserError2(dynamic raw) {
  final map = expectMap(
    raw,
    label: 'SignInWithUsernamePasswordResult2UserError2',
  );
  if (!map.containsKey('error')) {
    throw FormatException(
      'Missing required field "error" for SignInWithUsernamePasswordResult2UserError2',
    );
  }
  if (!map.containsKey('maximumLength')) {
    throw FormatException(
      'Missing required field "maximumLength" for SignInWithUsernamePasswordResult2UserError2',
    );
  }
  return (
    error: expectLiteral<String>(
      map['error'],
      'PASSWORD_TOO_LONG',
      label: 'SignInWithUsernamePasswordResult2UserError2Error',
    ),
    maximumLength: expectDouble(
      map['maximumLength'],
      label: 'SignInWithUsernamePasswordResult2UserError2MaximumLength',
    ),
  );
}

typedef SignInWithUsernamePasswordResult2UserError3 = ({String error});

Map<String, dynamic> _encodeSignInWithUsernamePasswordResult2UserError3(
  SignInWithUsernamePasswordResult2UserError3 value$,
) {
  final (error: error) = value$;
  return <String, dynamic>{'error': error};
}

SignInWithUsernamePasswordResult2UserError3
_decodeSignInWithUsernamePasswordResult2UserError3(dynamic raw) {
  final map = expectMap(
    raw,
    label: 'SignInWithUsernamePasswordResult2UserError3',
  );
  if (!map.containsKey('error')) {
    throw FormatException(
      'Missing required field "error" for SignInWithUsernamePasswordResult2UserError3',
    );
  }
  return (
    error: expectLiteral<String>(
      map['error'],
      'PASSWORD_HAS_SURROUNDING_WHITESPACE',
      label: 'SignInWithUsernamePasswordResult2UserError3Error',
    ),
  );
}

typedef SignInWithUsernamePasswordResult2UserError4 = ({String error});

Map<String, dynamic> _encodeSignInWithUsernamePasswordResult2UserError4(
  SignInWithUsernamePasswordResult2UserError4 value$,
) {
  final (error: error) = value$;
  return <String, dynamic>{'error': error};
}

SignInWithUsernamePasswordResult2UserError4
_decodeSignInWithUsernamePasswordResult2UserError4(dynamic raw) {
  final map = expectMap(
    raw,
    label: 'SignInWithUsernamePasswordResult2UserError4',
  );
  if (!map.containsKey('error')) {
    throw FormatException(
      'Missing required field "error" for SignInWithUsernamePasswordResult2UserError4',
    );
  }
  return (
    error: expectLiteral<String>(
      map['error'],
      'INVALID_CREDENTIALS',
      label: 'SignInWithUsernamePasswordResult2UserError4Error',
    ),
  );
}

typedef SignInWithUsernamePasswordResult2UserError5 = ({
  String error,
  double retryAfterMs,
});

Map<String, dynamic> _encodeSignInWithUsernamePasswordResult2UserError5(
  SignInWithUsernamePasswordResult2UserError5 value$,
) {
  final (error: error, retryAfterMs: retryAfterMs) = value$;
  return <String, dynamic>{'error': error, 'retryAfterMs': retryAfterMs};
}

SignInWithUsernamePasswordResult2UserError5
_decodeSignInWithUsernamePasswordResult2UserError5(dynamic raw) {
  final map = expectMap(
    raw,
    label: 'SignInWithUsernamePasswordResult2UserError5',
  );
  if (!map.containsKey('error')) {
    throw FormatException(
      'Missing required field "error" for SignInWithUsernamePasswordResult2UserError5',
    );
  }
  if (!map.containsKey('retryAfterMs')) {
    throw FormatException(
      'Missing required field "retryAfterMs" for SignInWithUsernamePasswordResult2UserError5',
    );
  }
  return (
    error: expectLiteral<String>(
      map['error'],
      'RATE_LIMITED',
      label: 'SignInWithUsernamePasswordResult2UserError5Error',
    ),
    retryAfterMs: expectDouble(
      map['retryAfterMs'],
      label: 'SignInWithUsernamePasswordResult2UserError5RetryAfterMs',
    ),
  );
}

typedef SignInWithUsernamePasswordResult2UserError6 = ({String error});

Map<String, dynamic> _encodeSignInWithUsernamePasswordResult2UserError6(
  SignInWithUsernamePasswordResult2UserError6 value$,
) {
  final (error: error) = value$;
  return <String, dynamic>{'error': error};
}

SignInWithUsernamePasswordResult2UserError6
_decodeSignInWithUsernamePasswordResult2UserError6(dynamic raw) {
  final map = expectMap(
    raw,
    label: 'SignInWithUsernamePasswordResult2UserError6',
  );
  if (!map.containsKey('error')) {
    throw FormatException(
      'Missing required field "error" for SignInWithUsernamePasswordResult2UserError6',
    );
  }
  return (
    error: expectLiteral<String>(
      map['error'],
      'USER_NOT_FOUND',
      label: 'SignInWithUsernamePasswordResult2UserError6Error',
    ),
  );
}

sealed class SignInWithUsernamePasswordResult2UserError {
  const SignInWithUsernamePasswordResult2UserError();
}

class SignInWithUsernamePasswordResult2UserError1Value
    extends SignInWithUsernamePasswordResult2UserError {
  const SignInWithUsernamePasswordResult2UserError1Value(this.value);
  final SignInWithUsernamePasswordResult2UserError1 value;
}

class SignInWithUsernamePasswordResult2UserError2Value
    extends SignInWithUsernamePasswordResult2UserError {
  const SignInWithUsernamePasswordResult2UserError2Value(this.value);
  final SignInWithUsernamePasswordResult2UserError2 value;
}

class SignInWithUsernamePasswordResult2UserError3Value
    extends SignInWithUsernamePasswordResult2UserError {
  const SignInWithUsernamePasswordResult2UserError3Value(this.value);
  final SignInWithUsernamePasswordResult2UserError3 value;
}

class SignInWithUsernamePasswordResult2UserError4Value
    extends SignInWithUsernamePasswordResult2UserError {
  const SignInWithUsernamePasswordResult2UserError4Value(this.value);
  final SignInWithUsernamePasswordResult2UserError4 value;
}

class SignInWithUsernamePasswordResult2UserError5Value
    extends SignInWithUsernamePasswordResult2UserError {
  const SignInWithUsernamePasswordResult2UserError5Value(this.value);
  final SignInWithUsernamePasswordResult2UserError5 value;
}

class SignInWithUsernamePasswordResult2UserError6Value
    extends SignInWithUsernamePasswordResult2UserError {
  const SignInWithUsernamePasswordResult2UserError6Value(this.value);
  final SignInWithUsernamePasswordResult2UserError6 value;
}

dynamic _encodeSignInWithUsernamePasswordResult2UserError(
  SignInWithUsernamePasswordResult2UserError value,
) {
  switch (value) {
    case SignInWithUsernamePasswordResult2UserError1Value(value: final inner):
      return _encodeSignInWithUsernamePasswordResult2UserError1(inner);
    case SignInWithUsernamePasswordResult2UserError2Value(value: final inner):
      return _encodeSignInWithUsernamePasswordResult2UserError2(inner);
    case SignInWithUsernamePasswordResult2UserError3Value(value: final inner):
      return _encodeSignInWithUsernamePasswordResult2UserError3(inner);
    case SignInWithUsernamePasswordResult2UserError4Value(value: final inner):
      return _encodeSignInWithUsernamePasswordResult2UserError4(inner);
    case SignInWithUsernamePasswordResult2UserError5Value(value: final inner):
      return _encodeSignInWithUsernamePasswordResult2UserError5(inner);
    case SignInWithUsernamePasswordResult2UserError6Value(value: final inner):
      return _encodeSignInWithUsernamePasswordResult2UserError6(inner);
  }
}

SignInWithUsernamePasswordResult2UserError
_decodeSignInWithUsernamePasswordResult2UserError(dynamic raw) {
  final errors = <String>[];
  try {
    return SignInWithUsernamePasswordResult2UserError1Value(
      _decodeSignInWithUsernamePasswordResult2UserError1(raw),
    );
  } catch (e) {
    errors.add('SignInWithUsernamePasswordResult2UserError1Value: $e');
  }
  try {
    return SignInWithUsernamePasswordResult2UserError2Value(
      _decodeSignInWithUsernamePasswordResult2UserError2(raw),
    );
  } catch (e) {
    errors.add('SignInWithUsernamePasswordResult2UserError2Value: $e');
  }
  try {
    return SignInWithUsernamePasswordResult2UserError3Value(
      _decodeSignInWithUsernamePasswordResult2UserError3(raw),
    );
  } catch (e) {
    errors.add('SignInWithUsernamePasswordResult2UserError3Value: $e');
  }
  try {
    return SignInWithUsernamePasswordResult2UserError4Value(
      _decodeSignInWithUsernamePasswordResult2UserError4(raw),
    );
  } catch (e) {
    errors.add('SignInWithUsernamePasswordResult2UserError4Value: $e');
  }
  try {
    return SignInWithUsernamePasswordResult2UserError5Value(
      _decodeSignInWithUsernamePasswordResult2UserError5(raw),
    );
  } catch (e) {
    errors.add('SignInWithUsernamePasswordResult2UserError5Value: $e');
  }
  try {
    return SignInWithUsernamePasswordResult2UserError6Value(
      _decodeSignInWithUsernamePasswordResult2UserError6(raw),
    );
  } catch (e) {
    errors.add('SignInWithUsernamePasswordResult2UserError6Value: $e');
  }
  throw FormatException(
    'Expected SignInWithUsernamePasswordResult2UserError but received ${describeType(raw)}.\n'
    'Tried: ${errors.join(", ")}',
  );
}

typedef SignInWithUsernamePasswordResult2 = ({
  String status,
  SignInWithUsernamePasswordResult2UserError userError,
});

Map<String, dynamic> _encodeSignInWithUsernamePasswordResult2(
  SignInWithUsernamePasswordResult2 value$,
) {
  final (status: status, userError: userError) = value$;
  return <String, dynamic>{
    'status': status,
    'userError': _encodeSignInWithUsernamePasswordResult2UserError(userError),
  };
}

SignInWithUsernamePasswordResult2 _decodeSignInWithUsernamePasswordResult2(
  dynamic raw,
) {
  final map = expectMap(raw, label: 'SignInWithUsernamePasswordResult2');
  if (!map.containsKey('status')) {
    throw FormatException(
      'Missing required field "status" for SignInWithUsernamePasswordResult2',
    );
  }
  if (!map.containsKey('userError')) {
    throw FormatException(
      'Missing required field "userError" for SignInWithUsernamePasswordResult2',
    );
  }
  return (
    status: expectLiteral<String>(
      map['status'],
      'error',
      label: 'SignInWithUsernamePasswordResult2Status',
    ),
    userError: _decodeSignInWithUsernamePasswordResult2UserError(
      map['userError'],
    ),
  );
}

sealed class SignInWithUsernamePasswordResult {
  const SignInWithUsernamePasswordResult();
}

class SignInWithUsernamePasswordResult1Value
    extends SignInWithUsernamePasswordResult {
  const SignInWithUsernamePasswordResult1Value(this.value);
  final SignInWithUsernamePasswordResult1 value;
}

class SignInWithUsernamePasswordResult2Value
    extends SignInWithUsernamePasswordResult {
  const SignInWithUsernamePasswordResult2Value(this.value);
  final SignInWithUsernamePasswordResult2 value;
}

dynamic _encodeSignInWithUsernamePasswordResult(
  SignInWithUsernamePasswordResult value,
) {
  switch (value) {
    case SignInWithUsernamePasswordResult1Value(value: final inner):
      return _encodeSignInWithUsernamePasswordResult1(inner);
    case SignInWithUsernamePasswordResult2Value(value: final inner):
      return _encodeSignInWithUsernamePasswordResult2(inner);
  }
}

SignInWithUsernamePasswordResult _decodeSignInWithUsernamePasswordResult(
  dynamic raw,
) {
  final errors = <String>[];
  try {
    return SignInWithUsernamePasswordResult1Value(
      _decodeSignInWithUsernamePasswordResult1(raw),
    );
  } catch (e) {
    errors.add('SignInWithUsernamePasswordResult1Value: $e');
  }
  try {
    return SignInWithUsernamePasswordResult2Value(
      _decodeSignInWithUsernamePasswordResult2(raw),
    );
  } catch (e) {
    errors.add('SignInWithUsernamePasswordResult2Value: $e');
  }
  throw FormatException(
    'Expected SignInWithUsernamePasswordResult but received ${describeType(raw)}.\n'
    'Tried: ${errors.join(", ")}',
  );
}

typedef SignInWithUsernamePasswordArgs = ({String password, String username});

Map<String, dynamic> _encodeSignInWithUsernamePasswordArgs(
  SignInWithUsernamePasswordArgs value$,
) {
  final (password: password, username: username) = value$;
  return <String, dynamic>{'password': password, 'username': username};
}

SignInWithUsernamePasswordArgs _decodeSignInWithUsernamePasswordArgs(
  dynamic raw,
) {
  final map = expectMap(raw, label: 'SignInWithUsernamePasswordArgs');
  if (!map.containsKey('password')) {
    throw FormatException(
      'Missing required field "password" for SignInWithUsernamePasswordArgs',
    );
  }
  if (!map.containsKey('username')) {
    throw FormatException(
      'Missing required field "username" for SignInWithUsernamePasswordArgs',
    );
  }
  return (
    password: expectString(
      map['password'],
      label: 'SignInWithUsernamePasswordArgsPassword',
    ),
    username: expectString(
      map['username'],
      label: 'SignInWithUsernamePasswordArgsUsername',
    ),
  );
}

typedef SignOutArgs = ({String refreshToken});

Map<String, dynamic> _encodeSignOutArgs(SignOutArgs value$) {
  final (refreshToken: refreshToken) = value$;
  return <String, dynamic>{'refreshToken': refreshToken};
}

SignOutArgs _decodeSignOutArgs(dynamic raw) {
  final map = expectMap(raw, label: 'SignOutArgs');
  if (!map.containsKey('refreshToken')) {
    throw FormatException(
      'Missing required field "refreshToken" for SignOutArgs',
    );
  }
  return (
    refreshToken: expectString(
      map['refreshToken'],
      label: 'SignOutArgsRefreshToken',
    ),
  );
}

typedef SignUpWithUsernamePasswordResult1Tokens = ({
  String accessToken,
  String refreshToken,
  double refreshTokenExpiresAt,
  String userId,
});

Map<String, dynamic> _encodeSignUpWithUsernamePasswordResult1Tokens(
  SignUpWithUsernamePasswordResult1Tokens value$,
) {
  final (
    accessToken: accessToken,
    refreshToken: refreshToken,
    refreshTokenExpiresAt: refreshTokenExpiresAt,
    userId: userId,
  ) = value$;
  return <String, dynamic>{
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'refreshTokenExpiresAt': refreshTokenExpiresAt,
    'userId': userId,
  };
}

SignUpWithUsernamePasswordResult1Tokens
_decodeSignUpWithUsernamePasswordResult1Tokens(dynamic raw) {
  final map = expectMap(raw, label: 'SignUpWithUsernamePasswordResult1Tokens');
  if (!map.containsKey('accessToken')) {
    throw FormatException(
      'Missing required field "accessToken" for SignUpWithUsernamePasswordResult1Tokens',
    );
  }
  if (!map.containsKey('refreshToken')) {
    throw FormatException(
      'Missing required field "refreshToken" for SignUpWithUsernamePasswordResult1Tokens',
    );
  }
  if (!map.containsKey('refreshTokenExpiresAt')) {
    throw FormatException(
      'Missing required field "refreshTokenExpiresAt" for SignUpWithUsernamePasswordResult1Tokens',
    );
  }
  if (!map.containsKey('userId')) {
    throw FormatException(
      'Missing required field "userId" for SignUpWithUsernamePasswordResult1Tokens',
    );
  }
  return (
    accessToken: expectString(
      map['accessToken'],
      label: 'SignUpWithUsernamePasswordResult1TokensAccessToken',
    ),
    refreshToken: expectString(
      map['refreshToken'],
      label: 'SignUpWithUsernamePasswordResult1TokensRefreshToken',
    ),
    refreshTokenExpiresAt: expectDouble(
      map['refreshTokenExpiresAt'],
      label: 'SignUpWithUsernamePasswordResult1TokensRefreshTokenExpiresAt',
    ),
    userId: expectString(
      map['userId'],
      label: 'SignUpWithUsernamePasswordResult1TokensUserId',
    ),
  );
}

typedef SignUpWithUsernamePasswordResult1 = ({
  String status,
  SignUpWithUsernamePasswordResult1Tokens tokens,
});

Map<String, dynamic> _encodeSignUpWithUsernamePasswordResult1(
  SignUpWithUsernamePasswordResult1 value$,
) {
  final (status: status, tokens: tokens) = value$;
  return <String, dynamic>{
    'status': status,
    'tokens': _encodeSignUpWithUsernamePasswordResult1Tokens(tokens),
  };
}

SignUpWithUsernamePasswordResult1 _decodeSignUpWithUsernamePasswordResult1(
  dynamic raw,
) {
  final map = expectMap(raw, label: 'SignUpWithUsernamePasswordResult1');
  if (!map.containsKey('status')) {
    throw FormatException(
      'Missing required field "status" for SignUpWithUsernamePasswordResult1',
    );
  }
  if (!map.containsKey('tokens')) {
    throw FormatException(
      'Missing required field "tokens" for SignUpWithUsernamePasswordResult1',
    );
  }
  return (
    status: expectLiteral<String>(
      map['status'],
      'complete',
      label: 'SignUpWithUsernamePasswordResult1Status',
    ),
    tokens: _decodeSignUpWithUsernamePasswordResult1Tokens(map['tokens']),
  );
}

typedef SignUpWithUsernamePasswordResult2UserError1 = ({
  String error,
  double minimumLength,
});

Map<String, dynamic> _encodeSignUpWithUsernamePasswordResult2UserError1(
  SignUpWithUsernamePasswordResult2UserError1 value$,
) {
  final (error: error, minimumLength: minimumLength) = value$;
  return <String, dynamic>{'error': error, 'minimumLength': minimumLength};
}

SignUpWithUsernamePasswordResult2UserError1
_decodeSignUpWithUsernamePasswordResult2UserError1(dynamic raw) {
  final map = expectMap(
    raw,
    label: 'SignUpWithUsernamePasswordResult2UserError1',
  );
  if (!map.containsKey('error')) {
    throw FormatException(
      'Missing required field "error" for SignUpWithUsernamePasswordResult2UserError1',
    );
  }
  if (!map.containsKey('minimumLength')) {
    throw FormatException(
      'Missing required field "minimumLength" for SignUpWithUsernamePasswordResult2UserError1',
    );
  }
  return (
    error: expectLiteral<String>(
      map['error'],
      'PASSWORD_TOO_SHORT',
      label: 'SignUpWithUsernamePasswordResult2UserError1Error',
    ),
    minimumLength: expectDouble(
      map['minimumLength'],
      label: 'SignUpWithUsernamePasswordResult2UserError1MinimumLength',
    ),
  );
}

typedef SignUpWithUsernamePasswordResult2UserError2 = ({
  String error,
  double maximumLength,
});

Map<String, dynamic> _encodeSignUpWithUsernamePasswordResult2UserError2(
  SignUpWithUsernamePasswordResult2UserError2 value$,
) {
  final (error: error, maximumLength: maximumLength) = value$;
  return <String, dynamic>{'error': error, 'maximumLength': maximumLength};
}

SignUpWithUsernamePasswordResult2UserError2
_decodeSignUpWithUsernamePasswordResult2UserError2(dynamic raw) {
  final map = expectMap(
    raw,
    label: 'SignUpWithUsernamePasswordResult2UserError2',
  );
  if (!map.containsKey('error')) {
    throw FormatException(
      'Missing required field "error" for SignUpWithUsernamePasswordResult2UserError2',
    );
  }
  if (!map.containsKey('maximumLength')) {
    throw FormatException(
      'Missing required field "maximumLength" for SignUpWithUsernamePasswordResult2UserError2',
    );
  }
  return (
    error: expectLiteral<String>(
      map['error'],
      'PASSWORD_TOO_LONG',
      label: 'SignUpWithUsernamePasswordResult2UserError2Error',
    ),
    maximumLength: expectDouble(
      map['maximumLength'],
      label: 'SignUpWithUsernamePasswordResult2UserError2MaximumLength',
    ),
  );
}

typedef SignUpWithUsernamePasswordResult2UserError3 = ({String error});

Map<String, dynamic> _encodeSignUpWithUsernamePasswordResult2UserError3(
  SignUpWithUsernamePasswordResult2UserError3 value$,
) {
  final (error: error) = value$;
  return <String, dynamic>{'error': error};
}

SignUpWithUsernamePasswordResult2UserError3
_decodeSignUpWithUsernamePasswordResult2UserError3(dynamic raw) {
  final map = expectMap(
    raw,
    label: 'SignUpWithUsernamePasswordResult2UserError3',
  );
  if (!map.containsKey('error')) {
    throw FormatException(
      'Missing required field "error" for SignUpWithUsernamePasswordResult2UserError3',
    );
  }
  return (
    error: expectLiteral<String>(
      map['error'],
      'PASSWORD_HAS_SURROUNDING_WHITESPACE',
      label: 'SignUpWithUsernamePasswordResult2UserError3Error',
    ),
  );
}

typedef SignUpWithUsernamePasswordResult2UserError4 = ({String error});

Map<String, dynamic> _encodeSignUpWithUsernamePasswordResult2UserError4(
  SignUpWithUsernamePasswordResult2UserError4 value$,
) {
  final (error: error) = value$;
  return <String, dynamic>{'error': error};
}

SignUpWithUsernamePasswordResult2UserError4
_decodeSignUpWithUsernamePasswordResult2UserError4(dynamic raw) {
  final map = expectMap(
    raw,
    label: 'SignUpWithUsernamePasswordResult2UserError4',
  );
  if (!map.containsKey('error')) {
    throw FormatException(
      'Missing required field "error" for SignUpWithUsernamePasswordResult2UserError4',
    );
  }
  return (
    error: expectLiteral<String>(
      map['error'],
      'PASSWORD_TOO_COMMON',
      label: 'SignUpWithUsernamePasswordResult2UserError4Error',
    ),
  );
}

typedef SignUpWithUsernamePasswordResult2UserError5 = ({
  String error,
  double minimumLength,
});

Map<String, dynamic> _encodeSignUpWithUsernamePasswordResult2UserError5(
  SignUpWithUsernamePasswordResult2UserError5 value$,
) {
  final (error: error, minimumLength: minimumLength) = value$;
  return <String, dynamic>{'error': error, 'minimumLength': minimumLength};
}

SignUpWithUsernamePasswordResult2UserError5
_decodeSignUpWithUsernamePasswordResult2UserError5(dynamic raw) {
  final map = expectMap(
    raw,
    label: 'SignUpWithUsernamePasswordResult2UserError5',
  );
  if (!map.containsKey('error')) {
    throw FormatException(
      'Missing required field "error" for SignUpWithUsernamePasswordResult2UserError5',
    );
  }
  if (!map.containsKey('minimumLength')) {
    throw FormatException(
      'Missing required field "minimumLength" for SignUpWithUsernamePasswordResult2UserError5',
    );
  }
  return (
    error: expectLiteral<String>(
      map['error'],
      'USERNAME_TOO_SHORT',
      label: 'SignUpWithUsernamePasswordResult2UserError5Error',
    ),
    minimumLength: expectDouble(
      map['minimumLength'],
      label: 'SignUpWithUsernamePasswordResult2UserError5MinimumLength',
    ),
  );
}

typedef SignUpWithUsernamePasswordResult2UserError6 = ({
  String error,
  double maximumLength,
});

Map<String, dynamic> _encodeSignUpWithUsernamePasswordResult2UserError6(
  SignUpWithUsernamePasswordResult2UserError6 value$,
) {
  final (error: error, maximumLength: maximumLength) = value$;
  return <String, dynamic>{'error': error, 'maximumLength': maximumLength};
}

SignUpWithUsernamePasswordResult2UserError6
_decodeSignUpWithUsernamePasswordResult2UserError6(dynamic raw) {
  final map = expectMap(
    raw,
    label: 'SignUpWithUsernamePasswordResult2UserError6',
  );
  if (!map.containsKey('error')) {
    throw FormatException(
      'Missing required field "error" for SignUpWithUsernamePasswordResult2UserError6',
    );
  }
  if (!map.containsKey('maximumLength')) {
    throw FormatException(
      'Missing required field "maximumLength" for SignUpWithUsernamePasswordResult2UserError6',
    );
  }
  return (
    error: expectLiteral<String>(
      map['error'],
      'USERNAME_TOO_LONG',
      label: 'SignUpWithUsernamePasswordResult2UserError6Error',
    ),
    maximumLength: expectDouble(
      map['maximumLength'],
      label: 'SignUpWithUsernamePasswordResult2UserError6MaximumLength',
    ),
  );
}

typedef SignUpWithUsernamePasswordResult2UserError7 = ({String error});

Map<String, dynamic> _encodeSignUpWithUsernamePasswordResult2UserError7(
  SignUpWithUsernamePasswordResult2UserError7 value$,
) {
  final (error: error) = value$;
  return <String, dynamic>{'error': error};
}

SignUpWithUsernamePasswordResult2UserError7
_decodeSignUpWithUsernamePasswordResult2UserError7(dynamic raw) {
  final map = expectMap(
    raw,
    label: 'SignUpWithUsernamePasswordResult2UserError7',
  );
  if (!map.containsKey('error')) {
    throw FormatException(
      'Missing required field "error" for SignUpWithUsernamePasswordResult2UserError7',
    );
  }
  return (
    error: expectLiteral<String>(
      map['error'],
      'USERNAME_HAS_SURROUNDING_WHITESPACE',
      label: 'SignUpWithUsernamePasswordResult2UserError7Error',
    ),
  );
}

typedef SignUpWithUsernamePasswordResult2UserError8 = ({String error});

Map<String, dynamic> _encodeSignUpWithUsernamePasswordResult2UserError8(
  SignUpWithUsernamePasswordResult2UserError8 value$,
) {
  final (error: error) = value$;
  return <String, dynamic>{'error': error};
}

SignUpWithUsernamePasswordResult2UserError8
_decodeSignUpWithUsernamePasswordResult2UserError8(dynamic raw) {
  final map = expectMap(
    raw,
    label: 'SignUpWithUsernamePasswordResult2UserError8',
  );
  if (!map.containsKey('error')) {
    throw FormatException(
      'Missing required field "error" for SignUpWithUsernamePasswordResult2UserError8',
    );
  }
  return (
    error: expectLiteral<String>(
      map['error'],
      'USERNAME_HAS_INVALID_CHARACTERS',
      label: 'SignUpWithUsernamePasswordResult2UserError8Error',
    ),
  );
}

typedef SignUpWithUsernamePasswordResult2UserError9 = ({String error});

Map<String, dynamic> _encodeSignUpWithUsernamePasswordResult2UserError9(
  SignUpWithUsernamePasswordResult2UserError9 value$,
) {
  final (error: error) = value$;
  return <String, dynamic>{'error': error};
}

SignUpWithUsernamePasswordResult2UserError9
_decodeSignUpWithUsernamePasswordResult2UserError9(dynamic raw) {
  final map = expectMap(
    raw,
    label: 'SignUpWithUsernamePasswordResult2UserError9',
  );
  if (!map.containsKey('error')) {
    throw FormatException(
      'Missing required field "error" for SignUpWithUsernamePasswordResult2UserError9',
    );
  }
  return (
    error: expectLiteral<String>(
      map['error'],
      'USERNAME_TAKEN',
      label: 'SignUpWithUsernamePasswordResult2UserError9Error',
    ),
  );
}

sealed class SignUpWithUsernamePasswordResult2UserError {
  const SignUpWithUsernamePasswordResult2UserError();
}

class SignUpWithUsernamePasswordResult2UserError1Value
    extends SignUpWithUsernamePasswordResult2UserError {
  const SignUpWithUsernamePasswordResult2UserError1Value(this.value);
  final SignUpWithUsernamePasswordResult2UserError1 value;
}

class SignUpWithUsernamePasswordResult2UserError2Value
    extends SignUpWithUsernamePasswordResult2UserError {
  const SignUpWithUsernamePasswordResult2UserError2Value(this.value);
  final SignUpWithUsernamePasswordResult2UserError2 value;
}

class SignUpWithUsernamePasswordResult2UserError3Value
    extends SignUpWithUsernamePasswordResult2UserError {
  const SignUpWithUsernamePasswordResult2UserError3Value(this.value);
  final SignUpWithUsernamePasswordResult2UserError3 value;
}

class SignUpWithUsernamePasswordResult2UserError4Value
    extends SignUpWithUsernamePasswordResult2UserError {
  const SignUpWithUsernamePasswordResult2UserError4Value(this.value);
  final SignUpWithUsernamePasswordResult2UserError4 value;
}

class SignUpWithUsernamePasswordResult2UserError5Value
    extends SignUpWithUsernamePasswordResult2UserError {
  const SignUpWithUsernamePasswordResult2UserError5Value(this.value);
  final SignUpWithUsernamePasswordResult2UserError5 value;
}

class SignUpWithUsernamePasswordResult2UserError6Value
    extends SignUpWithUsernamePasswordResult2UserError {
  const SignUpWithUsernamePasswordResult2UserError6Value(this.value);
  final SignUpWithUsernamePasswordResult2UserError6 value;
}

class SignUpWithUsernamePasswordResult2UserError7Value
    extends SignUpWithUsernamePasswordResult2UserError {
  const SignUpWithUsernamePasswordResult2UserError7Value(this.value);
  final SignUpWithUsernamePasswordResult2UserError7 value;
}

class SignUpWithUsernamePasswordResult2UserError8Value
    extends SignUpWithUsernamePasswordResult2UserError {
  const SignUpWithUsernamePasswordResult2UserError8Value(this.value);
  final SignUpWithUsernamePasswordResult2UserError8 value;
}

class SignUpWithUsernamePasswordResult2UserError9Value
    extends SignUpWithUsernamePasswordResult2UserError {
  const SignUpWithUsernamePasswordResult2UserError9Value(this.value);
  final SignUpWithUsernamePasswordResult2UserError9 value;
}

dynamic _encodeSignUpWithUsernamePasswordResult2UserError(
  SignUpWithUsernamePasswordResult2UserError value,
) {
  switch (value) {
    case SignUpWithUsernamePasswordResult2UserError1Value(value: final inner):
      return _encodeSignUpWithUsernamePasswordResult2UserError1(inner);
    case SignUpWithUsernamePasswordResult2UserError2Value(value: final inner):
      return _encodeSignUpWithUsernamePasswordResult2UserError2(inner);
    case SignUpWithUsernamePasswordResult2UserError3Value(value: final inner):
      return _encodeSignUpWithUsernamePasswordResult2UserError3(inner);
    case SignUpWithUsernamePasswordResult2UserError4Value(value: final inner):
      return _encodeSignUpWithUsernamePasswordResult2UserError4(inner);
    case SignUpWithUsernamePasswordResult2UserError5Value(value: final inner):
      return _encodeSignUpWithUsernamePasswordResult2UserError5(inner);
    case SignUpWithUsernamePasswordResult2UserError6Value(value: final inner):
      return _encodeSignUpWithUsernamePasswordResult2UserError6(inner);
    case SignUpWithUsernamePasswordResult2UserError7Value(value: final inner):
      return _encodeSignUpWithUsernamePasswordResult2UserError7(inner);
    case SignUpWithUsernamePasswordResult2UserError8Value(value: final inner):
      return _encodeSignUpWithUsernamePasswordResult2UserError8(inner);
    case SignUpWithUsernamePasswordResult2UserError9Value(value: final inner):
      return _encodeSignUpWithUsernamePasswordResult2UserError9(inner);
  }
}

SignUpWithUsernamePasswordResult2UserError
_decodeSignUpWithUsernamePasswordResult2UserError(dynamic raw) {
  final errors = <String>[];
  try {
    return SignUpWithUsernamePasswordResult2UserError1Value(
      _decodeSignUpWithUsernamePasswordResult2UserError1(raw),
    );
  } catch (e) {
    errors.add('SignUpWithUsernamePasswordResult2UserError1Value: $e');
  }
  try {
    return SignUpWithUsernamePasswordResult2UserError2Value(
      _decodeSignUpWithUsernamePasswordResult2UserError2(raw),
    );
  } catch (e) {
    errors.add('SignUpWithUsernamePasswordResult2UserError2Value: $e');
  }
  try {
    return SignUpWithUsernamePasswordResult2UserError3Value(
      _decodeSignUpWithUsernamePasswordResult2UserError3(raw),
    );
  } catch (e) {
    errors.add('SignUpWithUsernamePasswordResult2UserError3Value: $e');
  }
  try {
    return SignUpWithUsernamePasswordResult2UserError4Value(
      _decodeSignUpWithUsernamePasswordResult2UserError4(raw),
    );
  } catch (e) {
    errors.add('SignUpWithUsernamePasswordResult2UserError4Value: $e');
  }
  try {
    return SignUpWithUsernamePasswordResult2UserError5Value(
      _decodeSignUpWithUsernamePasswordResult2UserError5(raw),
    );
  } catch (e) {
    errors.add('SignUpWithUsernamePasswordResult2UserError5Value: $e');
  }
  try {
    return SignUpWithUsernamePasswordResult2UserError6Value(
      _decodeSignUpWithUsernamePasswordResult2UserError6(raw),
    );
  } catch (e) {
    errors.add('SignUpWithUsernamePasswordResult2UserError6Value: $e');
  }
  try {
    return SignUpWithUsernamePasswordResult2UserError7Value(
      _decodeSignUpWithUsernamePasswordResult2UserError7(raw),
    );
  } catch (e) {
    errors.add('SignUpWithUsernamePasswordResult2UserError7Value: $e');
  }
  try {
    return SignUpWithUsernamePasswordResult2UserError8Value(
      _decodeSignUpWithUsernamePasswordResult2UserError8(raw),
    );
  } catch (e) {
    errors.add('SignUpWithUsernamePasswordResult2UserError8Value: $e');
  }
  try {
    return SignUpWithUsernamePasswordResult2UserError9Value(
      _decodeSignUpWithUsernamePasswordResult2UserError9(raw),
    );
  } catch (e) {
    errors.add('SignUpWithUsernamePasswordResult2UserError9Value: $e');
  }
  throw FormatException(
    'Expected SignUpWithUsernamePasswordResult2UserError but received ${describeType(raw)}.\n'
    'Tried: ${errors.join(", ")}',
  );
}

typedef SignUpWithUsernamePasswordResult2 = ({
  String status,
  SignUpWithUsernamePasswordResult2UserError userError,
});

Map<String, dynamic> _encodeSignUpWithUsernamePasswordResult2(
  SignUpWithUsernamePasswordResult2 value$,
) {
  final (status: status, userError: userError) = value$;
  return <String, dynamic>{
    'status': status,
    'userError': _encodeSignUpWithUsernamePasswordResult2UserError(userError),
  };
}

SignUpWithUsernamePasswordResult2 _decodeSignUpWithUsernamePasswordResult2(
  dynamic raw,
) {
  final map = expectMap(raw, label: 'SignUpWithUsernamePasswordResult2');
  if (!map.containsKey('status')) {
    throw FormatException(
      'Missing required field "status" for SignUpWithUsernamePasswordResult2',
    );
  }
  if (!map.containsKey('userError')) {
    throw FormatException(
      'Missing required field "userError" for SignUpWithUsernamePasswordResult2',
    );
  }
  return (
    status: expectLiteral<String>(
      map['status'],
      'error',
      label: 'SignUpWithUsernamePasswordResult2Status',
    ),
    userError: _decodeSignUpWithUsernamePasswordResult2UserError(
      map['userError'],
    ),
  );
}

sealed class SignUpWithUsernamePasswordResult {
  const SignUpWithUsernamePasswordResult();
}

class SignUpWithUsernamePasswordResult1Value
    extends SignUpWithUsernamePasswordResult {
  const SignUpWithUsernamePasswordResult1Value(this.value);
  final SignUpWithUsernamePasswordResult1 value;
}

class SignUpWithUsernamePasswordResult2Value
    extends SignUpWithUsernamePasswordResult {
  const SignUpWithUsernamePasswordResult2Value(this.value);
  final SignUpWithUsernamePasswordResult2 value;
}

dynamic _encodeSignUpWithUsernamePasswordResult(
  SignUpWithUsernamePasswordResult value,
) {
  switch (value) {
    case SignUpWithUsernamePasswordResult1Value(value: final inner):
      return _encodeSignUpWithUsernamePasswordResult1(inner);
    case SignUpWithUsernamePasswordResult2Value(value: final inner):
      return _encodeSignUpWithUsernamePasswordResult2(inner);
  }
}

SignUpWithUsernamePasswordResult _decodeSignUpWithUsernamePasswordResult(
  dynamic raw,
) {
  final errors = <String>[];
  try {
    return SignUpWithUsernamePasswordResult1Value(
      _decodeSignUpWithUsernamePasswordResult1(raw),
    );
  } catch (e) {
    errors.add('SignUpWithUsernamePasswordResult1Value: $e');
  }
  try {
    return SignUpWithUsernamePasswordResult2Value(
      _decodeSignUpWithUsernamePasswordResult2(raw),
    );
  } catch (e) {
    errors.add('SignUpWithUsernamePasswordResult2Value: $e');
  }
  throw FormatException(
    'Expected SignUpWithUsernamePasswordResult but received ${describeType(raw)}.\n'
    'Tried: ${errors.join(", ")}',
  );
}

typedef SignUpWithUsernamePasswordArgs = ({String password, String username});

Map<String, dynamic> _encodeSignUpWithUsernamePasswordArgs(
  SignUpWithUsernamePasswordArgs value$,
) {
  final (password: password, username: username) = value$;
  return <String, dynamic>{'password': password, 'username': username};
}

SignUpWithUsernamePasswordArgs _decodeSignUpWithUsernamePasswordArgs(
  dynamic raw,
) {
  final map = expectMap(raw, label: 'SignUpWithUsernamePasswordArgs');
  if (!map.containsKey('password')) {
    throw FormatException(
      'Missing required field "password" for SignUpWithUsernamePasswordArgs',
    );
  }
  if (!map.containsKey('username')) {
    throw FormatException(
      'Missing required field "username" for SignUpWithUsernamePasswordArgs',
    );
  }
  return (
    password: expectString(
      map['password'],
      label: 'SignUpWithUsernamePasswordArgsPassword',
    ),
    username: expectString(
      map['username'],
      label: 'SignUpWithUsernamePasswordArgsUsername',
    ),
  );
}
