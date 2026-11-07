import 'package:dartvex/dartvex.dart' show OptimisticUpdate;
import 'package:flutter/widgets.dart';

import 'request_state.dart';
import 'runtime_client.dart';
import 'safe_rebuild.dart';
import 'snapshot.dart';

/// Builder callback for [ConvexMutation].
typedef ConvexMutationBuilder<T> =
    Widget Function(
      BuildContext context,
      ConvexRequestExecutor<T> mutate,
      ConvexRequestSnapshot<T> snapshot,
    );

/// Widget that exposes an imperative Convex mutation and request snapshot.
///
/// The `mutate` executor is **single-flight**: while a call is in flight
/// (`snapshot.isLoading`), another call is not sent and its future rejects
/// with a [StateError] — unnoticed if the future is ignored. A mutation stays
/// in flight until the server confirms it, which includes the whole time the
/// client is offline and holds the mutation for the next reconnect. Disable
/// the trigger while `snapshot.isLoading`, or call
/// `ConvexProvider.of(context).mutate(...)` directly when several mutations
/// must be queued concurrently (for example a chat composer that can send
/// while offline):
///
/// ```dart
/// ConvexMutation<String>(
///   mutation: 'messages:send',
///   builder: (context, mutate, snapshot) => FilledButton(
///     onPressed: snapshot.isLoading ? null : () => mutate({'text': 'Hi'}),
///     child: const Text('Send'),
///   ),
/// )
/// ```
///
/// The executor may be called after the widget is unmounted (for example
/// from an async callback that awaited an upload first): the mutation is still
/// sent, only the snapshot is no longer updated. When [decode] throws, the
/// error is a [ConvexDecodeException] — the mutation itself succeeded.
class ConvexMutation<T> extends StatefulWidget {
  /// Creates a [ConvexMutation].
  const ConvexMutation({
    super.key,
    required this.mutation,
    required this.builder,
    this.decode,
    this.client,
    this.optimisticUpdate,
  });

  /// Convex mutation name to invoke.
  final String mutation;

  /// Optional decoder for the raw mutation result.
  final ConvexDecoder<T>? decode;

  /// Optional runtime client override.
  final ConvexRuntimeClient? client;

  /// Optional optimistic update applied while the mutation is in flight.
  ///
  /// Overlays query results locally the moment the mutation is sent and rolls
  /// back automatically when it completes or fails. See `ConvexClient.mutate`.
  final OptimisticUpdate? optimisticUpdate;

  /// Builder that receives the mutate callback and current request snapshot.
  final ConvexMutationBuilder<T> builder;

  @override
  State<ConvexMutation<T>> createState() => _ConvexMutationState<T>();
}

class _ConvexMutationState<T> extends State<ConvexMutation<T>>
    with
        ConvexSafeRebuild<ConvexMutation<T>>,
        ConvexRequestState<ConvexMutation<T>, T> {
  @override
  ConvexRuntimeClient? get clientOverride => widget.client;

  @override
  String get requestLabel => 'Mutation "${widget.mutation}"';

  @override
  ConvexDecoder<T>? get decoder => widget.decode;

  @override
  ConvexRequestCall captureRequest() {
    final mutationName = widget.mutation;
    final optimisticUpdate = widget.optimisticUpdate;
    return (client, args) =>
        client.mutate(mutationName, args, optimisticUpdate);
  }

  @override
  void didUpdateWidget(covariant ConvexMutation<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    updateRequestIdentity(nameChanged: oldWidget.mutation != widget.mutation);
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, runRequest, requestSnapshot);
  }
}
