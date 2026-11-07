import 'package:flutter/widgets.dart';

import 'request_state.dart';
import 'runtime_client.dart';
import 'safe_rebuild.dart';
import 'snapshot.dart';

/// Builder callback for [ConvexAction].
typedef ConvexActionBuilder<T> =
    Widget Function(
      BuildContext context,
      ConvexRequestExecutor<T> action,
      ConvexRequestSnapshot<T> snapshot,
    );

/// Widget that exposes an imperative Convex action and request snapshot to its child.
///
/// The `action` executor is **single-flight**: while a call is in flight
/// (`snapshot.isLoading`), another call is not sent and its future rejects
/// with a [StateError] — unnoticed if the future is ignored. Disable the
/// trigger while `snapshot.isLoading`, or call
/// `ConvexProvider.of(context).action(...)` directly for concurrent calls.
///
/// The executor may be called after the widget is unmounted: the action is
/// still sent, only the snapshot is no longer updated. When [decode] throws,
/// the error is a [ConvexDecodeException] — the action itself succeeded.
class ConvexAction<T> extends StatefulWidget {
  /// Creates a [ConvexAction].
  const ConvexAction({
    super.key,
    required this.action,
    required this.builder,
    this.decode,
    this.client,
  });

  /// Convex action name to invoke.
  final String action;

  /// Optional decoder for the raw action result.
  final ConvexDecoder<T>? decode;

  /// Optional runtime client override.
  final ConvexRuntimeClient? client;

  /// Builder that receives the action callback and current request snapshot.
  final ConvexActionBuilder<T> builder;

  @override
  State<ConvexAction<T>> createState() => _ConvexActionState<T>();
}

class _ConvexActionState<T> extends State<ConvexAction<T>>
    with
        ConvexSafeRebuild<ConvexAction<T>>,
        ConvexRequestState<ConvexAction<T>, T> {
  @override
  ConvexRuntimeClient? get clientOverride => widget.client;

  @override
  String get requestLabel => 'Action "${widget.action}"';

  @override
  ConvexDecoder<T>? get decoder => widget.decode;

  @override
  ConvexRequestCall captureRequest() {
    final actionName = widget.action;
    return (client, args) => client.action(actionName, args);
  }

  @override
  void didUpdateWidget(covariant ConvexAction<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    updateRequestIdentity(nameChanged: oldWidget.action != widget.action);
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, runRequest, requestSnapshot);
  }
}
