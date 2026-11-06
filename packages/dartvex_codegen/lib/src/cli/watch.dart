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
///
/// Builds a [WatchPathFilter] for [config]; watchers build one up front and
/// reuse it instead.
bool shouldIgnoreWatchEvent(String eventPath, GenerateConfig config) =>
    WatchPathFilter.forConfig(config).ignores(eventPath);

/// Decides which paths under a watched project are ignored by watch mode:
/// anything inside [ignoredWatchDirectoryNames] below the project directory,
/// and the output directory with everything in it.
///
/// Event paths are built by dart:io from the path that was watched, which may
/// name the project through a symlink (macOS `/var` vs `/private/var`, or the
/// current directory, which `getcwd` reports resolved), while the output
/// directory may be spelled the other way. Both directories are therefore
/// canonicalized once, and the output directory is matched under every
/// spelling (as given, canonical, and relative to the project as watched), so
/// per-event checks are pure string comparisons.
class WatchPathFilter {
  WatchPathFilter._(this._root, this._canonicalRoot, this._outputAliases);

  /// Creates a filter for events under [projectDirectory] (or under any path
  /// when it is `null`), ignoring [outputDirectory].
  factory WatchPathFilter({
    required String? projectDirectory,
    required String outputDirectory,
  }) {
    final output = _absolute(outputDirectory);
    final canonicalOutput = canonicalizeWatchPath(output);
    final aliases = <String>{output, canonicalOutput};
    String? root;
    String? canonicalRoot;
    if (projectDirectory != null) {
      root = _absolute(projectDirectory);
      canonicalRoot = canonicalizeWatchPath(root);
      if (path.equals(canonicalOutput, canonicalRoot)) {
        aliases.add(root);
      } else if (path.isWithin(canonicalRoot, canonicalOutput)) {
        aliases.add(
          path.join(root, path.relative(canonicalOutput, from: canonicalRoot)),
        );
      }
    }
    return WatchPathFilter._(root, canonicalRoot, aliases.toList());
  }

  /// Creates the filter for the project and output directories of [config].
  factory WatchPathFilter.forConfig(GenerateConfig config) => WatchPathFilter(
    projectDirectory: config.projectDirectory,
    outputDirectory: config.outputDirectory,
  );

  final String? _root;
  final String? _canonicalRoot;
  final List<String> _outputAliases;

  /// Whether a change at [eventPath] should not trigger regeneration (and a
  /// directory at [eventPath] should not be watched).
  bool ignores(String eventPath) {
    final normalized = _absolute(eventPath);
    for (final output in _outputAliases) {
      if (path.equals(normalized, output) ||
          path.isWithin(output, normalized)) {
        return true;
      }
    }
    final relative = _relativeToProject(normalized);
    return relative != null &&
        path.split(relative).any(ignoredWatchDirectoryNames.contains);
  }

  /// [eventPath] relative to the project directory, or `null` when it is not
  /// inside it. Only components below the project count as ignored names, so
  /// a project that itself lives under, say, `node_modules` still works.
  String? _relativeToProject(String eventPath) {
    final root = _root;
    if (root == null) {
      return eventPath;
    }
    for (final base in <String>[root, _canonicalRoot!]) {
      if (path.isWithin(base, eventPath)) {
        return path.relative(eventPath, from: base);
      }
    }
    return null;
  }

  static String _absolute(String value) => path.normalize(path.absolute(value));
}

/// Returns [value] as an absolute path with symlinks resolved.
///
/// The longest existing prefix is resolved and the remaining components are
/// appended, so a directory that does not exist yet (an output directory
/// before the first generation) still canonicalizes consistently.
String canonicalizeWatchPath(String value) {
  var existing = path.normalize(path.absolute(value));
  final missing = <String>[];
  while (true) {
    try {
      if (FileSystemEntity.typeSync(existing) !=
          FileSystemEntityType.notFound) {
        final resolved = Directory(existing).resolveSymbolicLinksSync();
        return path.normalize(path.joinAll(<String>[resolved, ...missing]));
      }
    } on FileSystemException {
      // Unreadable or racing with a delete: fall back to the next ancestor.
    }
    final parent = path.dirname(existing);
    if (parent == existing) {
      return path.normalize(path.absolute(value));
    }
    missing.insert(0, path.basename(existing));
    existing = parent;
  }
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
/// Events inside ignored directories and the output directory are dropped
/// (see [WatchPathFilter]). On macOS, FSEvents may still report changes made
/// shortly *before* the watch started, so one extra trigger right after
/// startup is possible; regeneration skips a spec that did not change.
///
/// A watch error, or the root watch closing, is delivered as an error on
/// [triggers].
class SourceWatcher {
  SourceWatcher._(
    GenerateConfig config, {
    required Duration debounce,
    required List<Duration> pollDelays,
  }) : _debounceDuration = debounce,
       _pollDelays = pollDelays,
       _filter = WatchPathFilter.forConfig(config);

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

  final WatchPathFilter _filter;
  final Duration _debounceDuration;
  final List<Duration> _pollDelays;
  final StreamController<void> _controller = StreamController<void>();
  final Map<String, StreamSubscription<FileSystemEvent>> _subscriptions =
      <String, StreamSubscription<FileSystemEvent>>{};

  /// Canonical (symlink-resolved) path of every per-directory watch, keyed
  /// like [_subscriptions], so a directory reached both directly and through
  /// a symlink (or a symlink cycle) is watched only once.
  final Map<String, String> _canonicalWatched = <String, String>{};
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
    _canonicalWatched.clear();
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
        (!isRoot && _filter.ignores(normalized))) {
      return;
    }
    // A directory reached through a symlink is watched under the spelling it
    // was found by (event paths follow it), but only once per real directory:
    // the canonical path catches a second route to it and symlink cycles, and
    // also an ignored or output directory that the link renames.
    final canonical = canonicalizeWatchPath(normalized);
    if (_canonicalWatched.containsValue(canonical) ||
        (!isRoot && _filter.ignores(canonical))) {
      return;
    }
    _canonicalWatched[normalized] = canonical;
    void unwatch() {
      _subscriptions.remove(normalized)?.cancel();
      _canonicalWatched.remove(normalized);
    }

    // Arm the watch before listing children, so a subdirectory created in
    // between is reported by this watch rather than missed.
    _subscriptions[normalized] = Directory(normalized).watch().listen(
      (event) {
        if (_isIgnored(event)) {
          return;
        }
        if (event.type == FileSystemEvent.create &&
            (event.isDirectory || _isLinkToDirectory(event.path))) {
          _watchTree(event.path);
        } else if (event is FileSystemMoveEvent) {
          final destination = event.destination;
          if (destination != null &&
              (event.isDirectory || _isLinkToDirectory(destination))) {
            _watchTree(destination);
          }
        }
        _onChange();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!isRoot && !Directory(normalized).existsSync()) {
          // The directory vanished before (or while) it was watched.
          unwatch();
          return;
        }
        _fail(error, stackTrace);
      },
      onDone: () {
        _subscriptions.remove(normalized);
        _canonicalWatched.remove(normalized);
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
      if (child is Directory || _isLinkToDirectory(child.path)) {
        _watchTree(child.path);
      }
    }
  }

  /// Whether [entityPath] is a symlink that (eventually) resolves to a
  /// directory. Dangling links and links to files are not.
  static bool _isLinkToDirectory(String entityPath) {
    try {
      return FileSystemEntity.isLinkSync(entityPath) &&
          FileSystemEntity.isDirectorySync(entityPath);
    } on FileSystemException {
      return false;
    }
  }

  bool _isIgnored(FileSystemEvent event) {
    if (!_filter.ignores(event.path)) {
      return false;
    }
    final destination = event is FileSystemMoveEvent ? event.destination : null;
    return destination == null || _filter.ignores(destination);
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
