enum DartvexLogLevel {
  off,
  error,
  warn,
  info,
  debug,
}

class DartvexLogEvent {
  const DartvexLogEvent({
    required this.level,
    required this.message,
    this.tag,
    this.error,
    this.stackTrace,
    this.data,
  });

  final DartvexLogLevel level;
  final String message;
  final String? tag;
  final Object? error;
  final StackTrace? stackTrace;
  final Map<String, Object?>? data;
}

typedef DartvexLogger = void Function(DartvexLogEvent event);

abstract interface class DartvexLogSource {
  DartvexLogLevel get logLevel;
  DartvexLogger? get logger;
}

bool shouldEmitDartvexLog({
  required DartvexLogLevel configuredLevel,
  required DartvexLogLevel eventLevel,
}) {
  if (configuredLevel == DartvexLogLevel.off) {
    return false;
  }
  return eventLevel.index <= configuredLevel.index;
}

void emitDartvexLog({
  required DartvexLogLevel configuredLevel,
  required DartvexLogger? logger,
  required DartvexLogLevel eventLevel,
  required String message,
  String? tag,
  Object? error,
  StackTrace? stackTrace,
  Map<String, Object?>? data,
}) {
  if (!shouldEmitDartvexLog(
    configuredLevel: configuredLevel,
    eventLevel: eventLevel,
  )) {
    return;
  }
  final sink = logger;
  if (sink == null) {
    return;
  }
  sink(
    DartvexLogEvent(
      level: eventLevel,
      message: message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
      data: data,
    ),
  );
}
