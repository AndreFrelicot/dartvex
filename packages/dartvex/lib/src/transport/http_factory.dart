import 'package:http/http.dart' as http;

/// Process-wide override for the default HTTP client factory.
///
/// When non-null, [createDefaultHttpClient] delegates to this factory instead
/// of constructing a plain `package:http` [http.Client] (which uses `dart:io`
/// sockets on native platforms). Used by platform integrations (for example
/// `dartvex_flutter` on iOS/macOS, which installs an NSURLSession-backed
/// client at startup) so every HTTP request the SDK makes — storage uploads,
/// auth endpoints — travels the same system network path as the WebSocket
/// transport.
///
/// An explicitly provided client (for example `ConvexStorage(httpClient:)`)
/// always takes precedence: the override only applies where the default
/// client would have been constructed.
http.Client Function()? defaultHttpClientFactory;

/// Creates the default HTTP client used by the SDK.
///
/// Honors [defaultHttpClientFactory] when set; otherwise returns a plain
/// [http.Client]. Callers own the returned client and should `close()` it
/// when done, exactly as they would a client they constructed themselves.
http.Client createDefaultHttpClient() {
  final factory = defaultHttpClientFactory;
  if (factory != null) {
    return factory();
  }
  return http.Client();
}
