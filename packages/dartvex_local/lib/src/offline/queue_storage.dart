class StoredPendingMutation {
  const StoredPendingMutation({
    required this.id,
    required this.mutationName,
    required this.argsJson,
    required this.createdAtMillis,
    required this.status,
    this.optimisticJson,
    this.errorMessage,
  });

  final int id;
  final String mutationName;
  final String argsJson;
  final String? optimisticJson;
  final int createdAtMillis;
  final String status;
  final String? errorMessage;
}

abstract class QueueStorage {
  Future<StoredPendingMutation> enqueue({
    required String mutationName,
    required String argsJson,
    required String? optimisticJson,
    required int createdAtMillis,
  });

  Future<List<StoredPendingMutation>> loadAll();

  Future<void> markStatus(
    int id,
    String status, {
    String? errorMessage,
  });

  Future<void> remove(int id);

  Future<void> clearQueue();

  Future<void> updateArgs(int id, String argsJson);

  Future<void> saveIdRemap(String localId, String serverId);

  Future<Map<String, String>> loadIdRemaps();

  Future<void> clearIdRemaps();

  Future<void> close();
}
