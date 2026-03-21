/// Decodes a raw Convex value into an application type.
typedef ConvexDecoder<T> = T Function(dynamic value);

/// Executes a request-like Convex operation with optional arguments.
typedef ConvexRequestExecutor<T> = Future<T> Function(
    [Map<String, dynamic> args]);

/// Indicates where a query result originated.
enum ConvexQuerySource {
  /// The value came from the remote backend.
  remote,

  /// The value came from local cache state.
  cache,

  /// The source could not be determined.
  unknown,
}

const Object _snapshotSentinel = Object();

/// Immutable snapshot describing the state of a reactive query.
class ConvexQuerySnapshot<T> {
  /// Creates a query snapshot.
  const ConvexQuerySnapshot({
    required this.data,
    required this.error,
    required this.isLoading,
    required this.isRefreshing,
    required this.hasData,
    required this.hasError,
    required this.source,
    required this.hasPendingWrites,
  });

  /// Creates the initial loading snapshot for a query.
  const ConvexQuerySnapshot.initial()
      : data = null,
        error = null,
        isLoading = true,
        isRefreshing = false,
        hasData = false,
        hasError = false,
        source = ConvexQuerySource.unknown,
        hasPendingWrites = false;

  /// Latest decoded data, if available.
  final T? data;

  /// Latest query error, if any.
  final Object? error;

  /// Whether the initial load is still in progress.
  final bool isLoading;

  /// Whether existing data is being refreshed.
  final bool isRefreshing;

  /// Whether [data] is non-null and should be considered usable.
  final bool hasData;

  /// Whether [error] contains a current error.
  final bool hasError;

  /// Where the latest value or error originated.
  final ConvexQuerySource source;

  /// Whether optimistic writes are pending against the query.
  final bool hasPendingWrites;

  /// Returns a copy with selected fields replaced.
  ConvexQuerySnapshot<T> copyWith({
    Object? data = _snapshotSentinel,
    Object? error = _snapshotSentinel,
    bool? isLoading,
    bool? isRefreshing,
    bool? hasData,
    bool? hasError,
    ConvexQuerySource? source,
    bool? hasPendingWrites,
  }) {
    return ConvexQuerySnapshot<T>(
      data: identical(data, _snapshotSentinel) ? this.data : data as T?,
      error: identical(error, _snapshotSentinel) ? this.error : error,
      isLoading: isLoading ?? this.isLoading,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      hasData: hasData ?? this.hasData,
      hasError: hasError ?? this.hasError,
      source: source ?? this.source,
      hasPendingWrites: hasPendingWrites ?? this.hasPendingWrites,
    );
  }
}

/// Immutable snapshot describing the state of a one-shot request.
class ConvexRequestSnapshot<T> {
  /// Creates a request snapshot.
  const ConvexRequestSnapshot({
    required this.data,
    required this.error,
    required this.isLoading,
    required this.hasData,
    required this.hasError,
  });

  /// Creates the initial idle snapshot for a request.
  const ConvexRequestSnapshot.initial()
      : data = null,
        error = null,
        isLoading = false,
        hasData = false,
        hasError = false;

  /// Latest decoded data, if available.
  final T? data;

  /// Latest request error, if any.
  final Object? error;

  /// Whether the request is currently running.
  final bool isLoading;

  /// Whether [data] contains a successful result.
  final bool hasData;

  /// Whether [error] contains a current error.
  final bool hasError;

  /// Returns a copy with selected fields replaced.
  ConvexRequestSnapshot<T> copyWith({
    Object? data = _snapshotSentinel,
    Object? error = _snapshotSentinel,
    bool? isLoading,
    bool? hasData,
    bool? hasError,
  }) {
    return ConvexRequestSnapshot<T>(
      data: identical(data, _snapshotSentinel) ? this.data : data as T?,
      error: identical(error, _snapshotSentinel) ? this.error : error,
      isLoading: isLoading ?? this.isLoading,
      hasData: hasData ?? this.hasData,
      hasError: hasError ?? this.hasError,
    );
  }
}
