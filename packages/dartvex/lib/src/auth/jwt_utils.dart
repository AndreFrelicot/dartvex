import 'dart:convert';

/// Decodes the payload section of a JWT into a JSON object.
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
int? jwtExp(String token) {
  return decodeJwtPayload(token)['exp'] as int?;
}

/// Returns the JWT issued-at (`iat`) claim, if present.
int? jwtIat(String token) {
  return decodeJwtPayload(token)['iat'] as int?;
}
