// The web stand-ins are exported in place of the dart:io implementations on
// the web; they must accept the same constructor arguments and fail clearly.
import 'package:dartvex_flutter/src/native_only_stub.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'test_helpers/fake_runtime_client.dart';

void main() {
  group('web stand-ins', () {
    test('ConvexAssetCache rejects operations and disposes quietly', () async {
      final cache = ConvexAssetCache(
        cacheKey: 'k',
        stalePeriod: const Duration(days: 1),
        maxNrOfCacheObjects: 1,
      );
      ConvexAssetCache.custom(Object());

      await expectLater(
        cache.prefetch('k', 'https://example.com', force: true),
        throwsUnsupportedError,
      );
      await expectLater(cache.get('k'), throwsUnsupportedError);
      await expectLater(cache.contains('k'), throwsUnsupportedError);
      await expectLater(cache.remove('k'), throwsUnsupportedError);
      await expectLater(cache.clear(), throwsUnsupportedError);
      await expectLater(cache.getSizeBytes(), throwsUnsupportedError);
      await cache.dispose();
      expect(ConvexAssetCache.shared, isNotNull);
    });

    test('ConvexFileDownloader rejects downloads', () async {
      final client = http.Client();
      addTearDown(client.close);
      await expectLater(
        ConvexFileDownloader.download(
          'https://example.com',
          onProgress: (_) {},
          idleTimeout: const Duration(seconds: 1),
          client: client,
          abortTrigger: Future<void>.value(),
        ),
        throwsUnsupportedError,
      );
    });

    testWidgets('image widgets render their error state', (tester) async {
      final client = FakeRuntimeClient();
      final errors = <Object>[];

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              ConvexImage(
                storageId: 's',
                getUrlAction: 'files:getUrl',
                client: client,
                placeholder: const Text('loading'),
                errorWidget: const Text('ignored'),
                errorBuilder: (context, error, retry) {
                  errors.add(error);
                  return const Text('image error');
                },
                builder: (context, image) => const SizedBox(),
                progressBuilder: (context, progress) => const SizedBox(),
                onProgress: (_) {},
                useAction: true,
                fit: BoxFit.cover,
                width: 1,
                height: 1,
                httpClient: null,
              ),
              ConvexCachedImage(
                storageId: 's',
                getUrlAction: 'files:getUrl',
                cache: ConvexAssetCache.shared,
                client: client,
                placeholder: const Text('loading'),
                errorWidget: const Text('cached error'),
                builder: (context, image) => const SizedBox(),
                useAction: true,
                fit: BoxFit.cover,
                width: 1,
                height: 1,
              ),
              ConvexOfflineImage(
                cacheKey: 's',
                url: 'https://example.com',
                cache: ConvexAssetCache.shared,
                builder: (context, snapshot) {
                  errors.add(snapshot.error!);
                  expect(snapshot.hasError, isTrue);
                  expect(snapshot.hasFile, isFalse);
                  return const Text('offline error');
                },
              ),
            ],
          ),
        ),
      );

      expect(find.text('image error'), findsOneWidget);
      expect(find.text('cached error'), findsOneWidget);
      expect(find.text('offline error'), findsOneWidget);
      expect(errors, everyElement(isA<UnsupportedError>()));
      expect(const ConvexAssetSnapshot.loading().isLoading, isTrue);
    });
  });
}
