/// Log levels supported by Dartvex structured logging.
enum DartvexLogLevel {
  /// Disable all logging.
  off,

  /// Emit only errors.
  error,

  /// Emit warnings and errors.
  warn,

  /// Emit informational logs, warnings, and errors.
  info,

  /// Emit verbose debug logs in addition to all other levels.
  debug,
}

/// Structured log event emitted by Dartvex.
class DartvexLogEvent {
  /// Creates a structured log event.
  const DartvexLogEvent({
    required this.level,
    required this.message,
    this.tag,
    this.error,
    this.stackTrace,
    this.data,
  });

  /// Severity of the event.
  final DartvexLogLevel level;

  /// Human-readable log message.
  final String message;

  /// Optional subsystem tag.
  final String? tag;

  /// Optional associated error object.
  final Object? error;

  /// Optional stack trace associated with [error].
  final StackTrace? stackTrace;

  /// Optional structured diagnostic payload.
  final Map<String, Object?>? data;
}

/// Callback used to receive Dartvex log events.
typedef DartvexLogger = void Function(DartvexLogEvent event);

/// Interface implemented by objects that expose Dartvex logging settings.
abstract interface class DartvexLogSource {
  /// Minimum log level that should be emitted.
  DartvexLogLevel get logLevel;

  /// Sink that receives emitted log events.
  DartvexLogger? get logger;
}

/// Returns whether an event at [eventLevel] should be emitted.
bool shouldEmitDartvexLog({
  required DartvexLogLevel configuredLevel,
  required DartvexLogLevel eventLevel,
}) {
  if (configuredLevel == DartvexLogLevel.off) {
    return false;
  }
  return eventLevel.index <= configuredLevel.index;
}

/// Emits a structured Dartvex log event when logging is enabled.
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
