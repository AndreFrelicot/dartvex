import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:file/file.dart'; // ignore: depend_on_referenced_packages
import 'package:file/memory.dart'; // ignore: depend_on_referenced_packages
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConvexAssetCache', () {
    late FakeCacheManager fakeCacheManager;
    late ConvexAssetCache cache;

    setUp(() {
      fakeCacheManager = FakeCacheManager();
      cache = ConvexAssetCache.custom(fakeCacheManager);
    });

    test('prefetch downloads and caches by cacheKey', () async {
      final file = await cache.prefetch(
        'cache-123',
        'https://example.com/img.png',
      );

      expect(file, isNotNull);
      expect(fakeCacheManager.getSingleFileCalls, hasLength(1));
      expect(
        fakeCacheManager.getSingleFileCalls.first.key,
        'cache-123',
      );
      expect(
        fakeCacheManager.getSingleFileCalls.first.url,
        'https://example.com/img.png',
      );
    });

    test('prefetch returns cached file without downloading', () async {
      fakeCacheManager.putInCache('cache-456');

      final file = await cache.prefetch(
        'cache-456',
        'https://example.com/other.png',
      );

      expect(file, isNotNull);
      // Should NOT have called getSingleFile since cache was hit.
      expect(fakeCacheManager.getSingleFileCalls, isEmpty);
    });

    test('get returns cached file', () async {
      fakeCacheManager.putInCache('cache-abc');

      final file = await cache.get('cache-abc');
      expect(file, isNotNull);
    });

    test('get returns null for uncached cacheKey', () async {
      final file = await cache.get('nonexistent');
      expect(file, isNull);
    });

    test('contains returns true for cached asset', () async {
      fakeCacheManager.putInCache('cache-exists');

      expect(await cache.contains('cache-exists'), isTrue);
    });

    test('contains returns false for uncached asset', () async {
      expect(await cache.contains('nope'), isFalse);
    });

    test('remove deletes cached asset', () async {
      fakeCacheManager.putInCache('cache-del');

      await cache.remove('cache-del');

      expect(fakeCacheManager.removedKeys, contains('cache-del'));
    });

    test('clear empties all cached assets', () async {
      await cache.clear();

      expect(fakeCacheManager.emptyCacheCalled, isTrue);
    });
  });

  group('ConvexOfflineImage', () {
    late FakeCacheManager fakeCacheManager;
    late ConvexAssetCache cache;

    setUp(() {
      fakeCacheManager = FakeCacheManager();
      cache = ConvexAssetCache.custom(fakeCacheManager);
    });

    testWidgets('shows loading then cached file', (tester) async {
      fakeCacheManager.putInCache('img-1');

      final snapshots = <ConvexAssetSnapshot>[];

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexOfflineImage(
            cacheKey: 'img-1',
            url: 'https://example.com/img.png',
            cache: cache,
            builder: (context, snapshot) {
              snapshots.add(snapshot);
              if (snapshot.isLoading) return const Text('loading');
              if (snapshot.hasFile) return const Text('loaded');
              return const Text('error');
            },
          ),
        ),
      );

      // Initial build is loading.
      expect(find.text('loading'), findsOneWidget);

      await tester.pumpAndSettle();

      expect(find.text('loaded'), findsOneWidget);
      final last = snapshots.last;
      expect(last.hasFile, isTrue);
      expect(last.isCached, isTrue);
      expect(last.isLoading, isFalse);
    });

    testWidgets('downloads when not cached and url provided', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexOfflineImage(
            cacheKey: 'img-new',
            url: 'https://example.com/new.png',
            cache: cache,
            builder: (context, snapshot) {
              if (snapshot.isLoading) return const Text('loading');
              if (snapshot.hasFile) return const Text('downloaded');
              return const Text('error');
            },
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('downloaded'), findsOneWidget);
      expect(fakeCacheManager.getSingleFileCalls, hasLength(1));
    });

    testWidgets('shows error when no cache and no url', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexOfflineImage(
            cacheKey: 'img-offline',
            url: null,
            cache: cache,
            builder: (context, snapshot) {
              if (snapshot.isLoading) return const Text('loading');
              if (snapshot.hasError) return const Text('no-image');
              return const Text('ok');
            },
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('no-image'), findsOneWidget);
    });

    testWidgets('reloads when cacheKey changes', (tester) async {
      fakeCacheManager.putInCache('img-a');
      fakeCacheManager.putInCache('img-b');

      String currentId = 'img-a';

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: StatefulBuilder(
            builder: (context, setState) {
              return ConvexOfflineImage(
                cacheKey: currentId,
                url: 'https://example.com/$currentId.png',
                cache: cache,
                builder: (context, snapshot) {
                  return GestureDetector(
                    onTap: () => setState(() => currentId = 'img-b'),
                    child: Text(snapshot.hasFile ? currentId : 'loading'),
                  );
                },
              );
            },
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('img-a'), findsOneWidget);

      await tester.tap(find.text('img-a'));
      await tester.pumpAndSettle();
      expect(find.text('img-b'), findsOneWidget);
    });
  });
}

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

class GetSingleFileCall {
  const GetSingleFileCall(this.url, this.key);
  final String url;
  final String key;
}

class FakeCacheManager implements BaseCacheManager {
  final MemoryFileSystem _fs = MemoryFileSystem();
  final Map<String, FileInfo> _cache = {};
  final List<GetSingleFileCall> getSingleFileCalls = [];
  final List<String> removedKeys = [];
  bool emptyCacheCalled = false;

  File _createFile(String key) {
    final file = _fs.file('/cache/$key')
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[0]);
    return file;
  }

  void putInCache(String key) {
    _cache[key] = FileInfo(
      _createFile(key),
      FileSource.Cache,
      DateTime.now().add(const Duration(days: 30)),
      'https://example.com/$key',
    );
  }

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    return _cache[key];
  }

  @override
  Future<File> getSingleFile(
    String url, {
    String key = '',
    Map<String, String> headers = const {},
  }) async {
    getSingleFileCalls.add(GetSingleFileCall(url, key));
    final file = _createFile(key);
    _cache[key] = FileInfo(
      file,
      FileSource.Online,
      DateTime.now().add(const Duration(days: 30)),
      url,
    );
    return file;
  }

  @override
  Future<void> removeFile(String key) async {
    removedKeys.add(key);
    _cache.remove(key);
  }

  @override
  Future<void> emptyCache() async {
    emptyCacheCalled = true;
    _cache.clear();
  }

  @override
  Future<void> dispose() async {}

  // Unused methods — delegate to noSuchMethod.

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
