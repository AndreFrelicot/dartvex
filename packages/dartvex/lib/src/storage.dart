import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'client.dart';
import 'exceptions.dart';
import 'logging.dart';
import 'transport/http_factory.dart';

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
  /// 1. Calls [uploadUrlAction] to get a signed upload URL. It is invoked as a
  ///    Convex mutation by default; set [useAction] when the backend generates
  ///    upload URLs from an action.
  /// 2. POSTs [bytes] to that URL with the given [contentType].
  /// 3. Returns the `storageId` from the response.
  ///
  /// [filename] is only used for diagnostics (debug logging); it is not sent
  /// to Convex or stored with the file. Store it yourself, for example by
  /// passing it to the mutation that records the returned `storageId`.
  ///
  /// [timeout] bounds the upload request (sending the bytes and reading the
  /// response); when it expires the request is abandoned and a
  /// [TimeoutException] is thrown. It does not apply to the upload-URL call,
  /// which follows the client's own mutation/action timeouts. Defaults to no
  /// timeout.
  ///
  /// Throws [ConvexFileUploadException] if the upload HTTP request fails.
  Future<String> uploadFile({
    required String uploadUrlAction,
    required Uint8List bytes,
    String? filename,
    required String contentType,
    Map<String, dynamic>? uploadUrlArgs,
    bool useAction = false,
    Duration? timeout,
  }) async {
    if (timeout != null && timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
    _log(
      DartvexLogLevel.debug,
      'Starting file upload',
      data: <String, Object?>{
        'uploadUrlAction': uploadUrlAction,
        if (filename != null) 'filename': filename,
        'contentType': contentType,
        'sizeBytes': bytes.length,
      },
    );
    final urlArgs = uploadUrlArgs ?? const <String, dynamic>{};
    final uploadUrl = useAction
        ? await caller.action(uploadUrlAction, urlArgs)
        : await caller.mutate(uploadUrlAction, urlArgs);

    final uri = _parseUploadUri(uploadUrlAction, uploadUrl);
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      _log(
        DartvexLogLevel.error,
        'Upload URL has invalid scheme',
        data: <String, Object?>{'scheme': uri.scheme},
      );
      throw ConvexStorageException(
        'Upload URL resolver returned an unsupported URL scheme: ${uri.scheme}',
      );
    }
    if (uri.host.isEmpty) {
      _log(
        DartvexLogLevel.error,
        'Upload URL has no host',
        data: <String, Object?>{'url': uri.toString()},
      );
      throw const ConvexStorageException(
        'Upload URL resolver returned a URL with no host',
      );
    }

    final client = _httpClient ?? createDefaultHttpClient();
    try {
      final request = client.post(
        uri,
        headers: <String, String>{'Content-Type': contentType},
        body: bytes,
      );
      final http.Response response;
      if (timeout == null) {
        response = await request;
      } else {
        response = await request.timeout(
          timeout,
          onTimeout: () {
            _log(
              DartvexLogLevel.error,
              'File upload timed out',
              data: <String, Object?>{'timeoutMs': timeout.inMilliseconds},
            );
            throw TimeoutException(
              'File upload to Convex storage timed out after $timeout',
              timeout,
            );
          },
        );
      }

      if (response.statusCode != 200) {
        _log(
          DartvexLogLevel.error,
          'File upload failed',
          data: <String, Object?>{'statusCode': response.statusCode},
        );
        throw ConvexFileUploadException(response.statusCode, response.body);
      }

      final result = _decodeUploadResponse(response);
      _log(DartvexLogLevel.debug, 'File upload succeeded');
      return result;
    } finally {
      if (_httpClient == null) {
        client.close();
      }
    }
  }

  /// Get a download URL for a stored file.
  ///
  /// Calls [getUrlAction] with the given [storageId] and returns the signed
  /// download URL. By default this uses a Convex query; set [useAction] to
  /// true when the backend resolver is an action.
  Future<String> getFileUrl({
    required String getUrlAction,
    required String storageId,
    bool useAction = false,
  }) async {
    _log(
      DartvexLogLevel.debug,
      'Resolving file URL',
      data: <String, Object?>{
        'getUrlAction': getUrlAction,
        'storageId': storageId,
      },
    );
    final args = <String, dynamic>{'storageId': storageId};
    final url = useAction
        ? await caller.action(getUrlAction, args)
        : await caller.query(getUrlAction, args);
    _log(DartvexLogLevel.debug, 'Resolved file URL');
    if (url is String && url.isNotEmpty) {
      return url;
    }
    throw ConvexStorageException('No URL returned for storageId $storageId');
  }

  void _log(
    DartvexLogLevel level,
    String message, {
    Map<String, Object?>? data,
  }) {
    if (caller case final DartvexLogSource logSource) {
      emitDartvexLog(
        configuredLevel: logSource.logLevel,
        logger: logSource.logger,
        eventLevel: level,
        message: message,
        tag: 'storage',
        data: data,
      );
      return;
    }
  }

  Uri _parseUploadUri(String uploadUrlAction, Object? uploadUrl) {
    if (uploadUrl is! String || uploadUrl.isEmpty) {
      throw ConvexStorageException(
        'Upload URL resolver "$uploadUrlAction" must return a non-empty string',
      );
    }
    try {
      return Uri.parse(uploadUrl);
    } on FormatException catch (error) {
      throw ConvexStorageException(
        'Upload URL resolver "$uploadUrlAction" returned an invalid URL: '
        '${error.message}',
      );
    }
  }

  String _decodeUploadResponse(http.Response response) {
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw ConvexFileUploadException(
        response.statusCode,
        'Upload endpoint returned invalid JSON: ${response.body}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw ConvexFileUploadException(
        response.statusCode,
        'Upload endpoint returned a non-object JSON response',
      );
    }
    final storageId = decoded['storageId'];
    if (storageId is! String || storageId.isEmpty) {
      throw ConvexFileUploadException(
        response.statusCode,
        'Upload endpoint response is missing a non-empty string storageId',
      );
    }
    return storageId;
  }
}
