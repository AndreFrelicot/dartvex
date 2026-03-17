import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../cache/cache_storage.dart';
import '../offline/queue_storage.dart';

class SqliteLocalStore implements CacheStorage, QueueStorage {
  SqliteLocalStore._(
    this._database, {
    required bool deleteOnClose,
    String? databasePath,
  })  : _deleteOnClose = deleteOnClose,
        _databasePath = databasePath {
    _migrate();
  }

  final Database _database;
  final bool _deleteOnClose;
  final String? _databasePath;
  bool _closed = false;

  static Future<SqliteLocalStore> open(String path) async {
    final databaseFile = File(path);
    await databaseFile.parent.create(recursive: true);
    return SqliteLocalStore._(
      sqlite3.open(path),
      deleteOnClose: false,
      databasePath: path,
    );
  }

  static Future<SqliteLocalStore> openInMemory() async {
    return SqliteLocalStore._(sqlite3.openInMemory(), deleteOnClose: false);
  }

  @override
  Future<void> clearCache() async {
    final database = _assertOpen();
    database.execute('DELETE FROM query_cache;');
  }

  @override
  Future<void> clearQueue() async {
    final database = _assertOpen();
    database.execute('DELETE FROM mutation_queue;');
    database.execute('DELETE FROM id_remap;');
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _database.close();

    if (_deleteOnClose) {
      final databasePath = _databasePath;
      if (databasePath == null) {
        return;
      }
      final databaseFile = File(databasePath);
      final parent = databaseFile.parent;
      if (await databaseFile.exists()) {
        await databaseFile.delete();
      }
      if (await parent.exists()) {
        await parent.delete();
      }
    }
  }

  @override
  Future<StoredPendingMutation> enqueue({
    required String mutationName,
    required String argsJson,
    required String? optimisticJson,
    required int createdAtMillis,
  }) async {
    final database = _assertOpen();
    database.execute(
      '''
      INSERT INTO mutation_queue (
        mutation_name,
        args_json,
        optimistic_json,
        created_at,
        status
      ) VALUES (?, ?, ?, ?, 'pending');
      ''',
      <Object?>[mutationName, argsJson, optimisticJson, createdAtMillis],
    );
    final rows = database.select(
      '''
      SELECT id, mutation_name, args_json, optimistic_json, created_at, status,
             error_message
      FROM mutation_queue
      WHERE id = last_insert_rowid();
      ''',
    );
    return _storedPendingMutationFromRow(rows.single);
  }

  @override
  Future<List<StoredPendingMutation>> loadAll() async {
    final database = _assertOpen();
    final rows = database.select(
      '''
      SELECT id, mutation_name, args_json, optimistic_json, created_at, status,
             error_message
      FROM mutation_queue
      ORDER BY id ASC;
      ''',
    );
    return rows.map(_storedPendingMutationFromRow).toList(growable: false);
  }

  @override
  Future<void> markStatus(
    int id,
    String status, {
    String? errorMessage,
  }) async {
    final database = _assertOpen();
    database.execute(
      '''
      UPDATE mutation_queue
      SET status = ?,
          error_message = ?
      WHERE id = ?;
      ''',
      <Object?>[status, errorMessage, id],
    );
  }

  @override
  Future<StoredCacheEntry?> read(String key) async {
    final database = _assertOpen();
    final rows = database.select(
      '''
      SELECT key, query_name, args_json, value_json, updated_at
      FROM query_cache
      WHERE key = ?;
      ''',
      <Object?>[key],
    );
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.single;
    return StoredCacheEntry(
      key: row['key'] as String,
      queryName: row['query_name'] as String,
      argsJson: row['args_json'] as String,
      valueJson: row['value_json'] as String,
      updatedAtMillis: (row['updated_at'] as num).toInt(),
    );
  }

  @override
  Future<void> remove(int id) async {
    final database = _assertOpen();
    database.execute('DELETE FROM mutation_queue WHERE id = ?;', <Object?>[id]);
  }

  @override
  Future<void> updateArgs(int id, String argsJson) async {
    final database = _assertOpen();
    database.execute(
      'UPDATE mutation_queue SET args_json = ? WHERE id = ?;',
      <Object?>[argsJson, id],
    );
  }

  @override
  Future<void> saveIdRemap(String localId, String serverId) async {
    final database = _assertOpen();
    database.execute(
      '''
      INSERT INTO id_remap (local_id, server_id)
      VALUES (?, ?)
      ON CONFLICT(local_id) DO UPDATE SET server_id = excluded.server_id;
      ''',
      <Object?>[localId, serverId],
    );
  }

  @override
  Future<Map<String, String>> loadIdRemaps() async {
    final database = _assertOpen();
    final rows = database.select('SELECT local_id, server_id FROM id_remap;');
    return {
      for (final row in rows)
        row['local_id'] as String: row['server_id'] as String,
    };
  }

  @override
  Future<void> clearIdRemaps() async {
    final database = _assertOpen();
    database.execute('DELETE FROM id_remap;');
  }

  @override
  Future<void> upsert(StoredCacheEntry entry) async {
    final database = _assertOpen();
    database.execute(
      '''
      INSERT INTO query_cache (key, query_name, args_json, value_json, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET
        query_name = excluded.query_name,
        args_json = excluded.args_json,
        value_json = excluded.value_json,
        updated_at = excluded.updated_at;
      ''',
      <Object?>[
        entry.key,
        entry.queryName,
        entry.argsJson,
        entry.valueJson,
        entry.updatedAtMillis,
      ],
    );
  }

  Database _assertOpen() {
    if (_closed) {
      throw StateError('SqliteLocalStore has been closed');
    }
    return _database;
  }

  void _migrate() {
    final database = _assertOpen();
    database.execute(
      '''
      CREATE TABLE IF NOT EXISTS query_cache (
        key TEXT PRIMARY KEY,
        query_name TEXT NOT NULL,
        args_json TEXT NOT NULL,
        value_json TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      );
      ''',
    );
    database.execute(
      '''
      CREATE TABLE IF NOT EXISTS mutation_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        mutation_name TEXT NOT NULL,
        args_json TEXT NOT NULL,
        optimistic_json TEXT,
        created_at INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        error_message TEXT
      );
      ''',
    );
    database.execute(
      '''
      CREATE TABLE IF NOT EXISTS id_remap (
        local_id TEXT PRIMARY KEY,
        server_id TEXT NOT NULL
      );
      ''',
    );
  }

  StoredPendingMutation _storedPendingMutationFromRow(
      Map<String, dynamic> row) {
    return StoredPendingMutation(
      id: (row['id'] as num).toInt(),
      mutationName: row['mutation_name'] as String,
      argsJson: row['args_json'] as String,
      optimisticJson: row['optimistic_json'] as String?,
      createdAtMillis: (row['created_at'] as num).toInt(),
      status: row['status'] as String,
      errorMessage: row['error_message'] as String?,
    );
  }
}
