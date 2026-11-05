import 'dart:async';
import 'dart:io' as io;

import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:file/file.dart'; // ignore: depend_on_referenced_packages
import 'package:file/memory.dart'; // ignore: depend_on_referenced_packages
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'test_helpers/fake_runtime_client.dart';

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
      expect(fakeCacheManager.getSingleFileCalls.first.key, 'cache-123');
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

    test('prefetch can force-refresh an existing cache key', () async {
      fakeCacheManager.putInCache('cache-789');

      final file = await cache.prefetch(
        'cache-789',
        'https://example.com/refreshed.png',
        force: true,
      );

      expect(file, isNotNull);
      // Replaced in place: no remove-then-download window.
      expect(fakeCacheManager.removedKeys, isEmpty);
      expect(fakeCacheManager.getSingleFileCalls, isEmpty);
      expect(fakeCacheManager.downloadFileCalls, hasLength(1));
      expect(
        fakeCacheManager.downloadFileCalls.single.url,
        'https://example.com/refreshed.png',
      );
      expect(fakeCacheManager.downloadFileCalls.single.key, 'cache-789');
    });

    test('a failed forced refresh keeps the previously cached file', () async {
      fakeCacheManager.putInCache('cache-keep');
      final before = await cache.get('cache-keep');
      fakeCacheManager.downloadError = Exception('offline');

      await expectLater(
        cache.prefetch(
          'cache-keep',
          'https://example.com/new.png',
          force: true,
        ),
        throwsException,
      );

      expect(await cache.get('cache-keep'), isNotNull);
      expect((await cache.get('cache-keep'))!.path, before!.path);
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

    test(
      'getSizeBytes returns cache size from metrics-aware managers',
      () async {
        fakeCacheManager.putInCache('cache-size', byteCount: 42);

        final size = await cache.getSizeBytes();

        expect(size, 42);
      },
    );
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

    testWidgets('reloads when cache instance changes', (tester) async {
      final firstCacheManager = FakeCacheManager();
      final secondCacheManager = FakeCacheManager()..putInCache('img-shared');
      final firstCache = ConvexAssetCache.custom(firstCacheManager);
      final secondCache = ConvexAssetCache.custom(secondCacheManager);

      Widget build(ConvexAssetCache cache) {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexOfflineImage(
            cacheKey: 'img-shared',
            url: null,
            cache: cache,
            builder: (context, snapshot) {
              if (snapshot.isLoading) return const Text('loading');
              if (snapshot.hasFile) return const Text('loaded');
              return const Text('missing');
            },
          ),
        );
      }

      await tester.pumpWidget(build(firstCache));
      await tester.pumpAndSettle();

      expect(find.text('missing'), findsOneWidget);

      await tester.pumpWidget(build(secondCache));
      await tester.pumpAndSettle();

      expect(find.text('loaded'), findsOneWidget);
    });

    testWidgets('ignores stale async cache results after cacheKey changes', (
      tester,
    ) async {
      fakeCacheManager
        ..putInCache('img-a')
        ..putInCache('img-b')
        ..delayGet('img-a');

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexOfflineImage(
            cacheKey: 'img-a',
            url: null,
            cache: cache,
            builder: (context, snapshot) {
              return Text(snapshot.file?.path ?? 'loading');
            },
          ),
        ),
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexOfflineImage(
            cacheKey: 'img-b',
            url: null,
            cache: cache,
            builder: (context, snapshot) {
              return Text(snapshot.file?.path ?? 'loading');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('/cache/img-b'), findsOneWidget);
      fakeCacheManager.completeGet('img-a');
      await tester.pumpAndSettle();

      expect(find.text('/cache/img-b'), findsOneWidget);
      expect(find.text('/cache/img-a'), findsNothing);
    });
  });

  group('ConvexImage', () {
    testWidgets('resolves storage URLs with actions when requested', (
      tester,
    ) async {
      final client = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.connected,
      );
      client.onAction = (name, args) async => '';

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexImage(
            storageId: 'img-1',
            getUrlAction: 'files:getUrl',
            useAction: true,
            client: client,
            placeholder: const Text('loading'),
            errorWidget: const Text('error'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(client.actionCalls, hasLength(1));
      expect(client.actionCalls.single.name, 'files:getUrl');
      expect(client.actionCalls.single.args, const <String, dynamic>{
        'storageId': 'img-1',
      });
      expect(client.queryCalls, isEmpty);
      expect(find.text('error'), findsOneWidget);
    });

    testWidgets('reloads when the explicit client changes after an error', (
      tester,
    ) async {
      final firstClient = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.connected,
      );
      final secondClient = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.connected,
      );
      firstClient.onQuery = (name, args) async => '';
      secondClient.onQuery = (name, args) async => '';

      Widget build(FakeRuntimeClient client) {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexImage(
            storageId: 'img-1',
            getUrlAction: 'files:getUrl',
            client: client,
            placeholder: const Text('loading'),
            errorWidget: const Text('error'),
          ),
        );
      }

      await tester.pumpWidget(build(firstClient));
      await tester.pumpAndSettle();

      expect(firstClient.queryCalls, hasLength(1));
      expect(find.text('error'), findsOneWidget);

      await tester.pumpWidget(build(secondClient));
      await tester.pumpAndSettle();

      expect(secondClient.queryCalls, hasLength(1));
      expect(find.text('error'), findsOneWidget);
    });
  });

  group('ConvexCachedImage', () {
    late FakeCacheManager fakeCacheManager;
    late ConvexAssetCache cache;

    setUp(() {
      fakeCacheManager = FakeCacheManager();
      cache = ConvexAssetCache.custom(fakeCacheManager);
    });

    testWidgets('resolves cache-miss URLs with actions when requested', (
      tester,
    ) async {
      final client = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.connected,
      );
      client.onAction = (name, args) async => 'https://example.com/img.png';

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexCachedImage(
            storageId: 'img-1',
            getUrlAction: 'files:getUrl',
            useAction: true,
            cache: cache,
            client: client,
            placeholder: const Text('loading'),
            builder: (context, image) => const Text('loaded'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(client.actionCalls, hasLength(1));
      expect(client.actionCalls.single.name, 'files:getUrl');
      expect(client.actionCalls.single.args, const <String, dynamic>{
        'storageId': 'img-1',
      });
      expect(client.queryCalls, isEmpty);
      expect(fakeCacheManager.getSingleFileCalls, hasLength(1));
      expect(
        fakeCacheManager.getSingleFileCalls.single.url,
        'https://example.com/img.png',
      );
      expect(find.text('loaded'), findsOneWidget);
    });

    testWidgets('reloads when the provider client changes after load', (
      tester,
    ) async {
      final firstClient = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.connected,
      );
      final secondClient = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.connected,
      );
      firstClient.onQuery = (name, args) async => 'https://example.com/a.png';
      secondClient.onQuery = (name, args) async => 'https://example.com/b.png';

      Widget build(FakeRuntimeClient client) {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexProvider(
            client: client,
            child: ConvexCachedImage(
              storageId: 'img-1',
              getUrlAction: 'files:getUrl',
              cache: cache,
              placeholder: const Text('loading'),
              builder: (context, image) => const Text('loaded'),
            ),
          ),
        );
      }

      await tester.pumpWidget(build(firstClient));
      await tester.pumpAndSettle();

      expect(firstClient.queryCalls, hasLength(1));
      expect(fakeCacheManager.getSingleFileCalls, hasLength(1));
      expect(
        fakeCacheManager.getSingleFileCalls.single.url,
        'https://example.com/a.png',
      );

      await tester.pumpWidget(build(secondClient));
      await tester.pumpAndSettle();

      expect(secondClient.queryCalls, hasLength(1));
      // A client change bypasses the cache and force-refreshes in place.
      expect(fakeCacheManager.getSingleFileCalls, hasLength(1));
      expect(
        fakeCacheManager.downloadFileCalls.single.url,
        'https://example.com/b.png',
      );
      expect(find.text('loaded'), findsOneWidget);
    });

    testWidgets('reloads when the cache instance changes after load', (
      tester,
    ) async {
      final firstCacheManager = FakeCacheManager()..putInCache('img-1');
      final secondCacheManager = FakeCacheManager();
      final firstCache = ConvexAssetCache.custom(firstCacheManager);
      final secondCache = ConvexAssetCache.custom(secondCacheManager);
      final client = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.connected,
      );
      client.onQuery = (name, args) async => 'https://example.com/fresh.png';

      Widget build(ConvexAssetCache cache) {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexCachedImage(
            storageId: 'img-1',
            getUrlAction: 'files:getUrl',
            cache: cache,
            client: client,
            placeholder: const Text('loading'),
            builder: (context, image) => const Text('loaded'),
          ),
        );
      }

      await tester.pumpWidget(build(firstCache));
      await tester.pumpAndSettle();

      expect(find.text('loaded'), findsOneWidget);
      expect(client.queryCalls, isEmpty);

      await tester.pumpWidget(build(secondCache));
      await tester.pumpAndSettle();

      expect(client.queryCalls, hasLength(1));
      expect(secondCacheManager.getSingleFileCalls, hasLength(1));
      expect(
        secondCacheManager.getSingleFileCalls.single.url,
        'https://example.com/fresh.png',
      );
    });
  });

  group('image and cache fixes', () {
    group('shared store', () {
      late io.Directory dir;
      late List<FakeCacheInfoRepository> repositories;

      setUp(() {
        TestWidgetsFlutterBinding.ensureInitialized();
        dir = io.Directory.systemTemp.createTempSync('dartvex_cache_');
        // IOFileSystem resolves its directory through path_provider.
        const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(pathProvider, (_) async => dir.path);
        repositories = <FakeCacheInfoRepository>[];
        ConvexAssetCache.debugRepositoryFactory = (_) {
          final repository = FakeCacheInfoRepository();
          repositories.add(repository);
          return repository;
        };
        addTearDown(() {
          ConvexAssetCache.debugRepositoryFactory = null;
          messenger.setMockMethodCallHandler(pathProvider, null);
          dir.deleteSync(recursive: true);
        });
      });

      test('default-constructed caches with one cacheKey share a '
          'ref-counted store', () async {
        const key = 'dartvexFlutterTestRefCount';
        final a = ConvexAssetCache(cacheKey: key);
        final b = ConvexAssetCache(cacheKey: key);
        expect(ConvexAssetCache.debugReferenceCount(key), 2);
        expect(repositories, hasLength(1));
        expect(await b.contains('missing'), isFalse);

        await a.dispose();
        expect(ConvexAssetCache.debugReferenceCount(key), 1);
        // Disposing twice must not release the other instance's reference.
        await a.dispose();
        expect(ConvexAssetCache.debugReferenceCount(key), 1);
        expect(repositories.single.closeCalls, 0);

        await b.dispose();
        expect(ConvexAssetCache.debugReferenceCount(key), 0);
        expect(repositories.single.closeCalls, 1);

        // A new instance after the last dispose opens a fresh store.
        final c = ConvexAssetCache(cacheKey: key);
        expect(ConvexAssetCache.debugReferenceCount(key), 1);
        expect(repositories, hasLength(2));
        expect(await c.contains('missing'), isFalse);
        await c.dispose();
        expect(repositories.last.closeCalls, 1);
      });

      test('dispose while the store is still opening waits for the open, '
          'then closes', () async {
        final opening = Completer<void>();
        ConvexAssetCache.debugRepositoryFactory = (_) {
          final repository = FakeCacheInfoRepository(opening.future);
          repositories.add(repository);
          return repository;
        };
        final cache = ConvexAssetCache(cacheKey: 'dartvexFlutterTestOpening');

        var disposed = false;
        final dispose = cache.dispose().then((_) => disposed = true);
        await pumpEventQueue();
        expect(disposed, isFalse);
        expect(repositories.single.closeCalls, 0);

        opening.complete();
        await dispose;
        expect(repositories.single.closeCalls, 1);
      });

      test(
        'dispose after a failed open does not close the repository',
        () async {
          ConvexAssetCache.debugRepositoryFactory = (_) {
            final repository = FakeCacheInfoRepository(
              Future<void>.error(StateError('no SQLite plugin')),
            );
            repositories.add(repository);
            return repository;
          };
          final cache = ConvexAssetCache(cacheKey: 'dartvexFlutterTestFailed');
          await pumpEventQueue();

          await cache.dispose();
          expect(repositories.single.openCalls, 1);
          expect(repositories.single.closeCalls, 0);
        },
      );

      test('a store recreated while the previous one closes opens after the '
          'close', () async {
        const key = 'dartvexFlutterTestReopen';
        final first = ConvexAssetCache(cacheKey: key);
        await pumpEventQueue();
        final closing = Completer<void>();
        repositories.single.closeGate = closing.future;
        final firstDisposed = first.dispose();

        final second = ConvexAssetCache(cacheKey: key);
        await pumpEventQueue();
        expect(repositories, hasLength(2));
        expect(repositories.last.openCalls, 0);

        closing.complete();
        await firstDisposed;
        await pumpEventQueue();
        expect(repositories.last.openCalls, 1);
        await second.dispose();
      });

      test('disposing right after construction works with the built-in '
          'repositories', () async {
        // The JSON file backend (Linux, Windows) and the SQLite backend
        // (Android, iOS, macOS; its open fails here without the plugin)
        // both used to throw a null-check error from close().
        for (final create in <CacheInfoRepository Function()>[
          () => JsonCacheInfoRepository(
            path: '${dir.path}/dartvexFlutterTestJson.json',
          ),
          () => CacheObjectProvider(
            path: '${dir.path}/dartvexFlutterTestSqlite.db',
          ),
        ]) {
          ConvexAssetCache.debugRepositoryFactory = (_) => create();
          await ConvexAssetCache(
            cacheKey: 'dartvexFlutterTestBuiltIn',
          ).dispose();
          final reopened = ConvexAssetCache(
            cacheKey: 'dartvexFlutterTestBuiltIn',
          );
          await pumpEventQueue();
          await reopened.dispose();
        }
      });
    });

    testWidgets('ConvexOfflineImage does not flash loading when only the url '
        'changes', (tester) async {
      final manager = FakeCacheManager()..putInCache('img-1');
      final cache = ConvexAssetCache.custom(manager);
      final snapshots = <ConvexAssetSnapshot>[];

      Widget build(String? url) => Directionality(
        textDirection: TextDirection.ltr,
        child: ConvexOfflineImage(
          cacheKey: 'img-1',
          url: url,
          cache: cache,
          builder: (context, snapshot) {
            snapshots.add(snapshot);
            return const SizedBox();
          },
        ),
      );

      await tester.pumpWidget(build('https://example.com/a?sig=1'));
      await tester.pumpAndSettle();
      expect(snapshots.last.hasFile, isTrue);
      final loadedAt = snapshots.length;

      await tester.pumpWidget(build('https://example.com/a?sig=2'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(build(null));
      await tester.pumpAndSettle();

      expect(
        snapshots.skip(loadedAt).where((snapshot) => snapshot.isLoading),
        isEmpty,
      );
      expect(snapshots.last.hasFile, isTrue);
    });

    testWidgets('ConvexOfflineImage reports a typed error without cache or '
        'url', (tester) async {
      final cache = ConvexAssetCache.custom(FakeCacheManager());
      late ConvexAssetSnapshot latest;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexOfflineImage(
            cacheKey: 'missing',
            cache: cache,
            builder: (context, snapshot) {
              latest = snapshot;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(latest.hasError, isTrue);
      expect(latest.error, isA<ConvexStorageException>());
    });

    testWidgets('ConvexCachedImage errorBuilder retries the load', (
      tester,
    ) async {
      final manager = FakeCacheManager();
      final cache = ConvexAssetCache.custom(manager);
      final client = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.connected,
      );
      var calls = 0;
      client.onQuery = (name, args) async {
        calls += 1;
        if (calls == 1) {
          throw const ConvexStorageException('offline');
        }
        return 'https://example.com/img.png';
      };

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexCachedImage(
            storageId: 'img-1',
            getUrlAction: 'files:getUrl',
            cache: cache,
            client: client,
            errorBuilder: (context, error, retry) =>
                GestureDetector(onTap: retry, child: Text('retry: $error')),
            builder: (context, image) => const Text('loaded'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('retry:'), findsOneWidget);

      await tester.tap(find.textContaining('retry:'));
      await tester.pumpAndSettle();

      expect(find.text('loaded'), findsOneWidget);
      expect(calls, 2);
    });

    testWidgets('ConvexCachedImage reports errors without an error widget', (
      tester,
    ) async {
      final client = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.connected,
      );
      client.onQuery = (name, args) async => '';

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexCachedImage(
            storageId: 'img-1',
            getUrlAction: 'files:getUrl',
            cache: ConvexAssetCache.custom(FakeCacheManager()),
            client: client,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isA<ConvexStorageException>());
    });

    testWidgets('ConvexImage downloads through the injected client and retries '
        'from errorBuilder', (tester) async {
      final requests = <http.BaseRequest>[];
      final httpClient = MockClient.streaming((request, body) async {
        requests.add(request);
        return http.StreamedResponse(
          Stream<List<int>>.value(<int>[1, 2, 3]),
          200,
          contentLength: 3,
        );
      });
      final client = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.connected,
      );
      var calls = 0;
      client.onQuery = (name, args) async {
        calls += 1;
        return calls == 1 ? '' : 'https://example.com/img.png';
      };

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexImage(
            storageId: 'img-1',
            getUrlAction: 'files:getUrl',
            client: client,
            httpClient: httpClient,
            errorBuilder: (context, error, retry) =>
                GestureDetector(onTap: retry, child: Text('retry $error')),
            builder: (context, image) => const Text('loaded'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('retry'), findsOneWidget);
      expect(requests, isEmpty);

      await tester.tap(find.textContaining('retry'));
      await tester.pumpAndSettle();
      // Let the mocked transfer finish outside the fake clock.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      expect(find.text('loaded'), findsOneWidget);
      expect(requests.single.url, Uri.parse('https://example.com/img.png'));
      expect(requests.single, isA<http.Abortable>());
    });

    testWidgets('ConvexImage aborts its download when disposed', (
      tester,
    ) async {
      final requests = <http.BaseRequest>[];
      final body = StreamController<List<int>>();
      final httpClient = MockClient.streaming((request, _) async {
        requests.add(request);
        return http.StreamedResponse(body.stream, 200);
      });
      final client = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.connected,
      );
      client.onQuery = (name, args) async => 'https://example.com/big.png';

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexImage(
            storageId: 'img-1',
            getUrlAction: 'files:getUrl',
            client: client,
            httpClient: httpClient,
            placeholder: const Text('loading'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(requests, hasLength(1));
      var aborted = false;
      unawaited(
        (requests.single as http.Abortable).abortTrigger!.then((_) {
          aborted = true;
          // Like a real client: an aborted transfer ends its body stream.
          body.addError(http.RequestAbortedException());
          body.close();
        }),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();

      expect(aborted, isTrue);
    });

    testWidgets('ConvexImage reports errors without an error widget', (
      tester,
    ) async {
      final client = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.connected,
      );
      client.onQuery = (name, args) async => '';

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexImage(
            storageId: 'img-1',
            getUrlAction: 'files:getUrl',
            client: client,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isA<ConvexStorageException>());
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

class FakeCacheManager implements BaseCacheManager, ConvexAssetCacheMetrics {
  final MemoryFileSystem _fs = MemoryFileSystem();
  final Map<String, FileInfo> _cache = {};
  final Map<String, Completer<void>> _getDelays = {};
  final List<GetSingleFileCall> getSingleFileCalls = [];
  final List<GetSingleFileCall> downloadFileCalls = [];
  final List<String> removedKeys = [];
  bool emptyCacheCalled = false;
  Object? downloadError;

  File _createFile(String key) {
    final file = _fs.file('/cache/$key')
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[0]);
    return file;
  }

  void putInCache(String key, {int byteCount = 1}) {
    _cache[key] = FileInfo(
      _createFile(key)..writeAsBytesSync(List<int>.filled(byteCount, 0)),
      FileSource.Cache,
      DateTime.now().add(const Duration(days: 30)),
      'https://example.com/$key',
    );
  }

  void delayGet(String key) {
    _getDelays[key] = Completer<void>();
  }

  void completeGet(String key) {
    _getDelays.remove(key)?.complete();
  }

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    final delay = _getDelays[key];
    if (delay != null) {
      await delay.future;
    }
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
  Future<FileInfo> downloadFile(
    String url, {
    String? key,
    Map<String, String>? authHeaders,
    bool force = false,
  }) async {
    final cacheKey = key ?? url;
    downloadFileCalls.add(GetSingleFileCall(url, cacheKey));
    final error = downloadError;
    if (error != null) {
      throw error;
    }
    final info = FileInfo(
      _fs.file('/cache/$cacheKey.${downloadFileCalls.length}')
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1]),
      FileSource.Online,
      DateTime.now().add(const Duration(days: 30)),
      url,
    );
    _cache[cacheKey] = info;
    return info;
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

  @override
  Future<int> getSizeBytes() async {
    var total = 0;
    for (final info in _cache.values) {
      total += info.file.lengthSync();
    }
    return total;
  }

  // Unused methods — delegate to noSuchMethod.

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// In-memory [CacheInfoRepository] whose open and close can be held open.
class FakeCacheInfoRepository implements CacheInfoRepository {
  FakeCacheInfoRepository([this.openGate]);

  /// Completes (or fails) the open; `null` opens immediately.
  final Future<void>? openGate;

  /// Holds [close] until it completes.
  Future<void>? closeGate;

  int openCalls = 0;
  int closeCalls = 0;
  final Map<String, CacheObject> _objects = <String, CacheObject>{};

  @override
  Future<bool> open() async {
    openCalls += 1;
    await openGate;
    return true;
  }

  @override
  Future<bool> close() async {
    closeCalls += 1;
    await closeGate;
    return true;
  }

  @override
  Future<bool> exists() async => true;

  @override
  Future<CacheObject?> get(String key) async => _objects[key];

  @override
  Future<dynamic> updateOrInsert(CacheObject cacheObject) async =>
      _objects[cacheObject.key] = cacheObject;

  @override
  Future<CacheObject> insert(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) async => _objects[cacheObject.key] = cacheObject;

  @override
  Future<int> update(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) async {
    _objects[cacheObject.key] = cacheObject;
    return 1;
  }

  @override
  Future<int> delete(int id) async => 0;

  @override
  Future<int> deleteAll(Iterable<int> ids) async => 0;

  @override
  Future<List<CacheObject>> getAllObjects() async => _objects.values.toList();

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) async =>
      const <CacheObject>[];

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) async =>
      const <CacheObject>[];

  @override
  Future<void> deleteDataFile() async {}
}
