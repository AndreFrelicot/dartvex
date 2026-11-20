import 'dart:io';

/// Whether [error] is a `dart:io` network failure: what a token fetcher built
/// on `HttpClient` or a socket throws when the network is down or drops the
/// connection.
bool isIoNetworkError(Object error) =>
    error is SocketException ||
    error is HttpException ||
    error is HandshakeException;
