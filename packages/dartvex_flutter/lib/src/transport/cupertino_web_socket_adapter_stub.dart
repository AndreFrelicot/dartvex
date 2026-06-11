/// Web stand-in for the NSURLSession transport installer.
///
/// The Cupertino adapter depends on `dart:ffi`, which does not exist on the
/// web; this stub keeps the conditional import compilable there. It is never
/// invoked: plugin registration only runs on iOS and macOS.
void installCupertinoTransport() {}
