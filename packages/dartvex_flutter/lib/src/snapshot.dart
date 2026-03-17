typedef ConvexDecoder<T> = T Function(dynamic value);
typedef ConvexRequestExecutor<T> = Future<T> Function(
    [Map<String, dynamic> args]);

enum ConvexQuerySource { remote, cache, unknown }

const Object _snapshotSentinel = Object();

class ConvexQuerySnapshot<T> {
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

  const ConvexQuerySnapshot.initial()
      : data = null,
        error = null,
        isLoading = true,
        isRefreshing = false,
        hasData = false,
        hasError = false,
        source = ConvexQuerySource.unknown,
        hasPendingWrites = false;

  final T? data;
  final Object? error;
  final bool isLoading;
  final bool isRefreshing;
  final bool hasData;
  final bool hasError;
  final ConvexQuerySource source;
  final bool hasPendingWrites;

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

class ConvexRequestSnapshot<T> {
  const ConvexRequestSnapshot({
    required this.data,
    required this.error,
    required this.isLoading,
    required this.hasData,
    required this.hasError,
  });

  const ConvexRequestSnapshot.initial()
      : data = null,
        error = null,
        isLoading = false,
        hasData = false,
        hasError = false;

  final T? data;
  final Object? error;
  final bool isLoading;
  final bool hasData;
  final bool hasError;

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
