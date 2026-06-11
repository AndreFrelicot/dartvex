import 'transport/cupertino_web_socket_adapter_stub.dart'
    if (dart.library.io) 'transport/cupertino_web_socket_adapter.dart' as impl;

/// Dart plugin entry point for `dartvex_flutter`.
///
/// Flutter's generated plugin registrant calls [registerWith] before `main()`
/// on the platforms declared in the pubspec (iOS and macOS). It installs the
/// NSURLSession-backed WebSocket transport as the process-wide default, so
/// every `ConvexClient` in the app — however it is constructed — uses the
/// system network stack instead of raw `dart:io` sockets on Apple platforms.
///
/// See `installCupertinoTransport` for the opt-out story.
class DartvexFlutterPlugin {
  /// Called by the Flutter plugin registrant; not for manual use.
  static void registerWith() {
    impl.installCupertinoTransport();
  }
}
