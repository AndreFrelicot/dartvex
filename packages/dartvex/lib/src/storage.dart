import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'client.dart';
import 'exceptions.dart';

/// Helper for uploading and downloading files via Convex storage.
///
/// Convex file storage works in two steps:
/// 1. Call a mutation to get a signed upload URL
/// 2. POST file bytes to that URL
///
/// ```dart
/// final storage = ConvexStorage(client);
/// final storageId = await storage.uploadFile(
///   uploadUrlAction: 'files:generateUploadUrl',
///   bytes: fileBytes,
///   filename: 'photo.jpg',
///   contentType: 'image/jpeg',
/// );
/// ```
class ConvexStorage {
  /// Creates a [ConvexStorage] helper backed by the given [caller].
  ///
  /// An optional [httpClient] can be provided for testing or custom
  /// configuration. If omitted, a default [http.Client] is used.
  ConvexStorage(this.caller, {http.Client? httpClient})
      : _httpClient = httpClient;

  /// The function caller used to invoke Convex mutations and queries.
  final ConvexFunctionCaller caller;
  final http.Client? _httpClient;

  /// Upload a file to Convex storage.
  ///
  /// 1. Calls [uploadUrlAction] (a Convex mutation) to get a signed upload URL.
  /// 2. POSTs [bytes] to that URL with the given [contentType].
  /// 3. Returns the `storageId` from the response.
  ///
  /// Throws [ConvexFileUploadException] if the upload HTTP request fails.
  Future<String> uploadFile({
    required String uploadUrlAction,
    required Uint8List bytes,
    required String filename,
    required String contentType,
    Map<String, dynamic>? uploadUrlArgs,
  }) async {
    final uploadUrl = await caller.mutate(
      uploadUrlAction,
      uploadUrlArgs ?? const <String, dynamic>{},
    );

    final uri = Uri.parse(uploadUrl as String);
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw ConvexFileUploadException(
        400,
        'Invalid upload URL scheme: ${uri.scheme}',
      );
    }

    final client = _httpClient ?? http.Client();
    try {
      final response = await client.post(
        uri,
        headers: <String, String>{'Content-Type': contentType},
        body: bytes,
      );

      if (response.statusCode != 200) {
        throw ConvexFileUploadException(response.statusCode, response.body);
      }

      final result = jsonDecode(response.body) as Map<String, dynamic>;
      return result['storageId'] as String;
    } finally {
      if (_httpClient == null) {
        client.close();
      }
    }
  }

  /// Get a download URL for a stored file.
  ///
  /// Calls [getUrlAction] (a Convex query or action) with the given
  /// [storageId] and returns the signed download URL.
  Future<String> getFileUrl({
    required String getUrlAction,
    required String storageId,
  }) async {
    final url = await caller.query(
      getUrlAction,
      <String, dynamic>{'storageId': storageId},
    );
    return url as String;
  }
}
