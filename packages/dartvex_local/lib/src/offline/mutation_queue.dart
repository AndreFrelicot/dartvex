import '../client.dart';
import '../value_codec.dart';
import 'queue_storage.dart';

/// High-level wrapper around [QueueStorage] that encodes and decodes mutations.
class MutationQueue {
  /// Creates a mutation queue backed by [storage] and [codec].
  const MutationQueue({
    required QueueStorage storage,
    required ValueCodec codec,
  })  : _storage = storage,
        _codec = codec;

  final QueueStorage _storage;
  final ValueCodec _codec;

  /// Enqueues a pending mutation and returns its decoded representation.
  Future<PendingMutation> enqueue({
    required String mutationName,
    required Map<String, dynamic> args,
    required Map<String, dynamic>? optimisticData,
    required DateTime createdAt,
  }) async {
    final stored = await _storage.enqueue(
      mutationName: mutationName,
      argsJson: _codec.encode(args),
      optimisticJson:
          optimisticData == null ? null : _codec.encode(optimisticData),
      createdAtMillis: createdAt.millisecondsSinceEpoch,
    );
    return _toPendingMutation(stored);
  }

  /// Loads all pending mutations from storage.
  Future<List<PendingMutation>> loadAll() async {
    final stored = await _storage.loadAll();
    return stored.map(_toPendingMutation).toList(growable: false);
  }

  /// Updates the replay [status] of the mutation identified by [id].
  Future<void> markStatus(
    int id,
    PendingMutationStatus status, {
    String? errorMessage,
  }) {
    return _storage.markStatus(
      id,
      status.wireName,
      errorMessage: errorMessage,
    );
  }

  /// Removes the pending mutation with [id].
  Future<void> remove(int id) => _storage.remove(id);

  /// Clears all queued mutations.
  Future<void> clear() => _storage.clearQueue();

  /// Replaces the queued mutation arguments for [id].
  Future<void> updateArgs(int id, Map<String, dynamic> args) =>
      _storage.updateArgs(id, _codec.encode(args));

  /// Persists a local-to-server document ID mapping.
  Future<void> saveIdRemap(String localId, String serverId) =>
      _storage.saveIdRemap(localId, serverId);

  /// Loads all persisted local-to-server document ID mappings.
  Future<Map<String, String>> loadIdRemaps() => _storage.loadIdRemaps();

  /// Clears all persisted ID mappings.
  Future<void> clearIdRemaps() => _storage.clearIdRemaps();

  PendingMutation _toPendingMutation(StoredPendingMutation stored) {
    return PendingMutation(
      id: stored.id,
      mutationName: stored.mutationName,
      args: _codec.decodeMap(stored.argsJson),
      optimisticData: stored.optimisticJson == null
          ? null
          : _codec.decodeMap(stored.optimisticJson!),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        stored.createdAtMillis,
        isUtc: true,
      ),
      status: PendingMutationStatusName.fromWireName(stored.status),
      errorMessage: stored.errorMessage,
    );
  }
}
