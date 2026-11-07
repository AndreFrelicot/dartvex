import 'dart:io';

import 'package:dartvex/dartvex.dart';
import 'package:test/test.dart';

import 'test_helpers/mock_web_socket_adapter.dart';

void main() {
  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  group('version constants', () {
    test('dartvexVersion matches the pubspec version', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final match =
          RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(pubspec);
      expect(match, isNotNull);
      expect(dartvexVersion, match!.group(1));
    });

    test('default clientId is a parseable <client>-<semver> identifier', () {
      const config = ConvexClientConfig();
      expect(config.clientId, 'dartvex-$dartvexVersion');
      expect(
        RegExp(r'^dartvex-\d+\.\d+\.\d+').hasMatch(config.clientId),
        isTrue,
      );
    });

    test('default apiVersion is the tracked sync protocol constant', () {
      const config = ConvexClientConfig();
      expect(config.apiVersion, convexSyncApiVersion);
      expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(convexSyncApiVersion), isTrue);
    });

    test('the WebSocket URL and adapter use the defaults', () async {
      final adapter = MockWebSocketAdapter();
      String? adapterClientId;
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (clientId) {
            adapterClientId = clientId;
            return adapter;
          },
        ),
      );
      await settle();
      expect(adapterClientId, 'dartvex-$dartvexVersion');
      expect(
        adapter.connectedUrls.single,
        'wss://demo.convex.cloud/api/$convexSyncApiVersion/sync',
      );
      await client.close();
    });
  });

  group('deployment URL validation', () {
    test('rejects a .convex.site HTTP Actions URL', () {
      expect(
        () => ConvexClient(
          'https://happy-animal-123.convex.site',
          config: const ConvexClientConfig(connectImmediately: false),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('.convex.cloud'),
          ),
        ),
      );
      expect(
        () => ConvexClient(
          'https://HAPPY-animal-123.CONVEX.SITE/',
          config: const ConvexClientConfig(connectImmediately: false),
        ),
        throwsArgumentError,
      );
    });

    test('accepts .convex.cloud, localhost, and custom domains', () async {
      for (final url in <String>[
        'https://happy-animal-123.convex.cloud',
        'http://127.0.0.1:3210',
        'https://convex.example.com',
      ]) {
        final client = ConvexClient(
          url,
          config: const ConvexClientConfig(connectImmediately: false),
        );
        await client.close();
      }
    });
  });

  group('expectAuth', () {
    List<String> sentTypes(MockWebSocketAdapter adapter) =>
        adapter.decodedSentMessages
            .map((message) => message['type'] as String)
            .toList();

    test('holds queries and mutations until setAuth decides the identity',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          expectAuth: true,
        ),
      );
      final subscription = client.subscribe('messages:list');
      final mutation = client.mutate('messages:send');
      mutation.ignore();
      await settle();

      expect(adapter.connectedUrls, hasLength(1));
      expect(sentTypes(adapter), isEmpty);

      await client.setAuth('token-a');
      await settle();

      final types = sentTypes(adapter);
      expect(types.first, 'Connect');
      final authIndex = types.indexOf('Authenticate');
      final querySetIndex = types.indexOf('ModifyQuerySet');
      final mutationIndex = types.indexOf('Mutation');
      expect(authIndex, greaterThan(0));
      expect(querySetIndex, greaterThan(authIndex));
      expect(mutationIndex, greaterThan(querySetIndex));
      final querySet = adapter.decodedSentMessages[querySetIndex];
      expect(querySet['modifications'], hasLength(1));

      subscription.cancel();
      await client.close();
    });

    test('clearAuth releases the pause without authenticating', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          expectAuth: true,
        ),
      );
      final subscription = client.subscribe('messages:list');
      await settle();
      expect(sentTypes(adapter), isEmpty);

      await client.clearAuth();
      await settle();

      final types = sentTypes(adapter);
      expect(types, containsAllInOrder(<String>['Connect', 'ModifyQuerySet']));
      expect(types, isNot(contains('Authenticate')));

      subscription.cancel();
      await client.close();
    });

    test('setAuthWithRefresh releases the pause once the token is fetched',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          expectAuth: true,
        ),
      );
      final subscription = client.subscribe('messages:list');
      await settle();
      expect(sentTypes(adapter), isEmpty);

      await client.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async => 'token-b',
      );
      await settle();

      final types = sentTypes(adapter);
      expect(
        types,
        containsAllInOrder(
          <String>['Connect', 'Authenticate', 'ModifyQuerySet'],
        ),
      );

      subscription.cancel();
      await client.close();
    });

    test('defaults to false', () {
      expect(const ConvexClientConfig().expectAuth, isFalse);
    });
  });
}
