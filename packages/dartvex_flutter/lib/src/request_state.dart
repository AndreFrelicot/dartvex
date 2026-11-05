import 'dart:async';

import 'package:flutter/widgets.dart';

import 'provider.dart';
import 'runtime_client.dart';
import 'safe_rebuild.dart';
import 'snapshot.dart';

/// Signature of a captured one-shot Convex call.
typedef ConvexRequestCall =
    Future<dynamic> Function(
      ConvexRuntimeClient client,
      Map<String, dynamic> args,
    );

/// Shared request state machine of `ConvexMutation` and `ConvexAction`.
///
/// * Single-flight: a call made while another is in flight is rejected with a
///   [StateError] (ignored by default so an unawaited call does not surface as
///   an unhandled zone error; awaiting callers still receive it).
/// * Request configuration (name, decoder, optimistic update) is captured when
///   the call starts; a change of request name or client invalidates the
///   snapshot and orphans any in-flight completion.
/// * The executor stays usable after the widget is unmounted: the request is
///   still sent through the captured client, only snapshot updates stop.
mixin ConvexRequestState<W extends StatefulWidget, T> on ConvexSafeRebuild<W> {
  ConvexRuntimeClient? _runtimeClient;
  ConvexRequestSnapshot<T> _requestSnapshot =
      ConvexRequestSnapshot<T>.initial();
  Future<T>? _inFlight;
  int _requestGeneration = 0;

  /// The current request snapshot.
  ConvexRequestSnapshot<T> get requestSnapshot => _requestSnapshot;

  /// The explicit client override of the widget, if any.
  @protected
  ConvexRuntimeClient? get clientOverride;

  /// Human-readable request label, e.g. `Mutation "tasks:create"`.
  @protected
  String get requestLabel;

  /// The widget's current result decoder.
  @protected
  ConvexDecoder<T>? get decoder;

  /// Captures the widget's current request configuration.
  @protected
  ConvexRequestCall captureRequest();

  ConvexRuntimeClient _resolveClient() =>
      clientOverride ?? ConvexProvider.of(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final resolvedClient = _resolveClient();
    if (_runtimeClient == null) {
      _runtimeClient = resolvedClient;
      return;
    }
    if (_runtimeClient != resolvedClient) {
      _runtimeClient = resolvedClient;
      _invalidateRequestState();
    }
  }

  /// Call from `didUpdateWidget`. [nameChanged] reports whether the request
  /// name changed; decoders and optimistic updates are captured per request
  /// and are not part of the identity (inline closures differ on every parent
  /// rebuild and must not wipe the snapshot or orphan an in-flight request).
  @protected
  void updateRequestIdentity({required bool nameChanged}) {
    final resolvedClient = _resolveClient();
    final identityChanged = nameChanged || _runtimeClient != resolvedClient;
    _runtimeClient = resolvedClient;
    if (identityChanged) {
      _invalidateRequestState();
    }
  }

  @override
  void dispose() {
    _requestGeneration += 1;
    super.dispose();
  }

  /// Runs the request with [args]; the executor handed to builders.
  Future<T> runRequest([
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    final active = _inFlight;
    if (active != null) {
      // ignore() keeps an ignored return value (the normal builder pattern,
      // where the snapshot carries the state) from surfacing as an unhandled
      // zone error; awaiting callers still receive the StateError.
      final rejection = Future<T>.error(
        StateError('$requestLabel is already in progress.'),
      );
      rejection.ignore();
      return rejection;
    }
    final completer = Completer<T>();
    final future = completer.future;
    // The builder API intentionally lets callers ignore the returned future
    // and observe failures through the snapshot.
    future.ignore();
    _inFlight = future;
    final generation = ++_requestGeneration;
    final runtimeClient = _runtimeClient!;
    final call = captureRequest();
    final decode = decoder;
    // The executor is often captured by an async callback that awaits other
    // work first; once the widget is gone the request is still sent, only the
    // snapshot is no longer updated.
    if (mounted) {
      applyAndRebuild(() {
        _requestSnapshot = _requestSnapshot.copyWith(
          error: null,
          isLoading: true,
          hasError: false,
        );
      });
    }

    () async {
      try {
        final raw = await call(runtimeClient, args);
        final T decoded;
        try {
          decoded = decode != null ? decode(raw) : raw as T;
        } catch (error, stackTrace) {
          // The server already succeeded (for a mutation: the write is
          // committed); tell that apart from a rejected request.
          throw ConvexDecodeException(error, stackTrace, value: raw);
        }
        if (mounted && generation == _requestGeneration) {
          applyAndRebuild(() {
            _requestSnapshot = ConvexRequestSnapshot<T>(
              data: decoded,
              error: null,
              isLoading: false,
              hasData: true,
              hasError: false,
            );
          });
        }
        completer.complete(decoded);
      } catch (error, stackTrace) {
        if (mounted && generation == _requestGeneration) {
          applyAndRebuild(() {
            _requestSnapshot = _requestSnapshot.copyWith(
              error: error,
              isLoading: false,
              hasError: true,
            );
          });
        }
        completer.completeError(error, stackTrace);
      } finally {
        // Compared by identity, not generation: dispose() bumps the
        // generation too, and the executor must stay usable after unmount.
        // An invalidation already cleared (or replaced) the slot.
        if (identical(_inFlight, future)) {
          _inFlight = null;
        }
      }
    }();

    return future;
  }

  void _invalidateRequestState() {
    _requestGeneration += 1;
    _inFlight = null;
    if (!mounted) {
      return;
    }
    // Only called from lifecycle callbacks, which are followed by a build.
    _requestSnapshot = ConvexRequestSnapshot<T>.initial();
  }
}
