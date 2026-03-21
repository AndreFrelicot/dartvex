/// Serialized mutation entry stored by a [QueueStorage] implementation.
class StoredPendingMutation {
  /// Creates a stored pending mutation record.
  const StoredPendingMutation({
    required this.id,
    required this.mutationName,
    required this.argsJson,
    required this.createdAtMillis,
    required this.status,
    this.optimisticJson,
    this.errorMessage,
  });

  /// Storage-assigned identifier for the queued mutation.
  final int id;

  /// Canonical mutation name to replay remotely.
  final String mutationName;

  /// Encoded JSON mutation arguments.
  final String argsJson;

  /// Encoded optimistic metadata used for replay and conflict recovery.
  final String? optimisticJson;

  /// UTC creation time in milliseconds since epoch.
  final int createdAtMillis;

  /// Wire representation of the pending mutation status.
  final String status;

  /// Optional error captured while replaying the mutation.
  final String? errorMessage;
}

/// Persistence interface for the offline mutation queue.
abstract class QueueStorage {
  /// Creates a queue storage implementation.
  QueueStorage();

  /// Enqueues a new mutation for later replay.
  Future<StoredPendingMutation> enqueue({
    required String mutationName,
    required String argsJson,
    required String? optimisticJson,
    required int createdAtMillis,
  });

  /// Loads all queued mutations in replay order.
  Future<List<StoredPendingMutation>> loadAll();

  /// Updates the replay [status] for the mutation with [id].
  Future<void> markStatus(
    int id,
    String status, {
    String? errorMessage,
  });

  /// Removes the queued mutation with [id].
  Future<void> remove(int id);

  /// Removes all queued mutations.
  Future<void> clearQueue();

  /// Replaces the encoded argument payload for the mutation with [id].
  Future<void> updateArgs(int id, String argsJson);

  /// Persists a mapping from a locally generated ID to a server-issued ID.
  Future<void> saveIdRemap(String localId, String serverId);

  /// Loads all persisted local-to-server ID mappings.
  Future<Map<String, String>> loadIdRemaps();

  /// Clears all persisted ID remappings.
  Future<void> clearIdRemaps();

  /// Releases any storage resources held by the implementation.
  Future<void> close();
}
