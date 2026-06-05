import 'dart:convert';

/// Decodes the payload section of a JWT into a JSON object.
///
/// This does not validate the JWT signature. Signature validation is performed
/// by the Convex backend on authenticated requests; this helper is only used
/// to read non-security-sensitive claims such as `exp` and `iat` for refresh
/// scheduling.
Map<String, dynamic> decodeJwtPayload(String token) {
  final parts = token.split('.');
  if (parts.length < 2) {
    throw const FormatException('JWT must contain at least two segments');
  }
  final normalized = base64Url.normalize(parts[1]);
  final decoded = utf8.decode(base64Url.decode(normalized));
  final json = jsonDecode(decoded);
  if (json is! Map<String, dynamic>) {
    throw const FormatException('JWT payload must decode to an object');
  }
  return json;
}

/// Returns the JWT expiration (`exp`) claim, if present.
///
/// Reads the claim defensively: a numeric value is coerced to an `int`, and a
/// missing or non-numeric claim yields `null` rather than throwing a cast
/// error. This keeps a malformed token from escaping refresh scheduling as an
/// unhandled error that would otherwise tear down the connection.
int? jwtExp(String token) => _readIntClaim(decodeJwtPayload(token)['exp']);

/// Returns the JWT issued-at (`iat`) claim, if present.
///
/// Uses the same defensive numeric coercion as [jwtExp].
int? jwtIat(String token) => _readIntClaim(decodeJwtPayload(token)['iat']);

int? _readIntClaim(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return null;
}
