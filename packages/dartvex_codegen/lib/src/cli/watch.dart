import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'config.dart';

/// Directory names never watched or reacted to in project watch mode.
const Set<String> ignoredWatchDirectoryNames = <String>{
  '.dart_tool',
  '.git',
  'node_modules',
};

/// Returns whether a filesystem event should be ignored by watch mode.
bool shouldIgnoreWatchEvent(String eventPath, GenerateConfig config) {
  final normalized = path.normalize(path.absolute(eventPath));
  if (path.split(normalized).any(ignoredWatchDirectoryNames.contains)) {
    return true;
  }
  final outputDirectory = path.normalize(path.absolute(config.outputDirectory));
  return path.equals(normalized, outputDirectory) ||
      path.isWithin(outputDirectory, normalized);
}

/// Produces regeneration triggers for `generate --watch`.
///
/// Filesystem watches are armed as soon as the watcher is created, and
/// triggers are buffered until [triggers] is listened to, so changes made
/// while the initial generation runs are not lost.
///
/// * `--spec-file`: the spec file's parent directory is watched and events
///   are filtered by file name, so atomic replaces (`git checkout`, editor
///   safe-writes, `mv tmp spec.json`) keep working, and Windows (where
///   `File.watch` is unreliable) is supported.
/// * `--project`: the project directory is watched recursively. Linux (and
///   any platform other than macOS and Windows) ignores
///   `Directory.watch(recursive: true)`, so there every subdirectory gets its
///   own watch, skipping [ignoredWatchDirectoryNames] and the output
///   directory, and directories created later are added as they appear.
///   Because `convex function-spec` reads the deployed functions, each
///   change also schedules follow-up triggers at [pollDelays], catching a
///   `convex dev` push that finishes after the first regeneration.
///
/// A watch error, or the root watch closing, is delivered as an error on
/// [triggers].
class SourceWatcher {
  SourceWatcher._(
    this._config, {
    required Duration debounce,
    required List<Duration> pollDelays,
  }) : _debounceDuration = debounce,
       _pollDelays = pollDelays;

  /// Starts watching the spec source described by [config].
  ///
  /// [recursiveWatchSupported] defaults to `true` on macOS and Windows, the
  /// only platforms where dart:io honors recursive directory watches.
  factory SourceWatcher.start(
    GenerateConfig config, {
    Duration debounce = const Duration(milliseconds: 250),
    List<Duration> pollDelays = const <Duration>[],
    bool? recursiveWatchSupported,
  }) {
    final watcher = SourceWatcher._(
      config,
      debounce: debounce,
      pollDelays: config.specFile == null ? pollDelays : const <Duration>[],
    );
    final specFile = config.specFile;
    if (specFile != null) {
      watcher._watchSpecFile(specFile);
    } else if (recursiveWatchSupported ??
        (Platform.isMacOS || Platform.isWindows)) {
      watcher._watchRecursively(config.projectDirectory!);
    } else {
      watcher._watchTree(config.projectDirectory!, isRoot: true);
    }
    return watcher;
  }

  final GenerateConfig _config;
  final Duration _debounceDuration;
  final List<Duration> _pollDelays;
  final StreamController<void> _controller = StreamController<void>();
  final Map<String, StreamSubscription<FileSystemEvent>> _subscriptions =
      <String, StreamSubscription<FileSystemEvent>>{};
  final List<Timer> _pollTimers = <Timer>[];
  Timer? _debounce;
  bool _closed = false;

  /// Regeneration triggers. Errors are watch failures; the stream ends when
  /// [close] is called.
  Stream<void> get triggers => _controller.stream;

  /// The directories currently watched (one entry in recursive mode).
  Iterable<String> get watchedDirectories => _subscriptions.keys;

  /// Stops all watches and timers and closes [triggers].
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _debounce?.cancel();
    _cancelPolls();
    final subscriptions = _subscriptions.values.toList();
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    // Not awaited: the done future of a never-listened controller would
    // never complete.
    unawaited(_controller.close());
  }

  void _watchSpecFile(String specFile) {
    final directory = path.dirname(specFile);
    final name = path.basename(specFile);
    bool matches(String? eventPath) =>
        eventPath != null && path.basename(eventPath) == name;
    _subscriptions[directory] = Directory(directory).watch().listen(
      (event) {
        if (event.type == FileSystemEvent.delete) {
          // Wait for the file to be recreated; deleting the spec is part of
          // an atomic replace or a git checkout.
          return;
        }
        final destination =
            event is FileSystemMoveEvent ? event.destination : null;
        if (matches(event.path) || matches(destination)) {
          _onChange();
        }
      },
      onError: _fail,
      onDone: () => _rootClosed(directory),
    );
  }

  void _watchRecursively(String root) {
    _subscriptions[root] = Directory(root)
        .watch(recursive: true)
        .listen(
          (event) {
            if (!_isIgnored(event)) {
              _onChange();
            }
          },
          onError: _fail,
          onDone: () => _rootClosed(root),
        );
  }

  void _watchTree(String directory, {bool isRoot = false}) {
    final normalized = path.normalize(directory);
    if (_closed ||
        _subscriptions.containsKey(normalized) ||
        (!isRoot && shouldIgnoreWatchEvent(normalized, _config))) {
      return;
    }
    // Arm the watch before listing children, so a subdirectory created in
    // between is reported by this watch rather than missed.
    _subscriptions[normalized] = Directory(normalized).watch().listen(
      (event) {
        if (_isIgnored(event)) {
          return;
        }
        if (event.isDirectory) {
          if (event.type == FileSystemEvent.create) {
            _watchTree(event.path);
          } else if (event is FileSystemMoveEvent &&
              event.destination != null) {
            _watchTree(event.destination!);
          }
        }
        _onChange();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!isRoot && !Directory(normalized).existsSync()) {
          // The directory vanished before (or while) it was watched.
          _subscriptions.remove(normalized)?.cancel();
          return;
        }
        _fail(error, stackTrace);
      },
      onDone: () {
        _subscriptions.remove(normalized);
        if (isRoot) {
          _rootClosed(normalized);
        }
      },
    );
    final List<FileSystemEntity> children;
    try {
      children = Directory(normalized).listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final child in children) {
      if (child is Directory) {
        _watchTree(child.path);
      }
    }
  }

  bool _isIgnored(FileSystemEvent event) {
    if (!shouldIgnoreWatchEvent(event.path, _config)) {
      return false;
    }
    final destination = event is FileSystemMoveEvent ? event.destination : null;
    return destination == null || shouldIgnoreWatchEvent(destination, _config);
  }

  void _onChange() {
    if (_closed) {
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(_debounceDuration, () {
      _emit();
      _cancelPolls();
      for (final delay in _pollDelays) {
        _pollTimers.add(Timer(delay, _emit));
      }
    });
  }

  void _emit() {
    if (!_closed) {
      _controller.add(null);
    }
  }

  void _cancelPolls() {
    for (final timer in _pollTimers) {
      timer.cancel();
    }
    _pollTimers.clear();
  }

  void _fail(Object error, [StackTrace? stackTrace]) {
    if (!_closed) {
      _controller.addError(error, stackTrace);
      unawaited(close());
    }
  }

  void _rootClosed(String directory) {
    _fail(
      FileSystemException(
        'Watching stopped unexpectedly (was the directory removed?)',
        directory,
      ),
    );
  }
}
