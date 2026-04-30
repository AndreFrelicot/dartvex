import 'dart:async';
import 'package:dartvex/dartvex.dart';
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:dartvex/src/logging.dart';
import 'package:dartvex/src/transport/ws_manager.dart';
import 'package:test/test.dart';

import 'test_helpers/mock_web_socket_adapter.dart';

void main() {
  group('structured logging', () {
    test('does not emit logs by default', () async {
      final adapter = MockWebSocketAdapter();
      final events = <DartvexLogEvent>[];
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, isEmpty);
      client.dispose();
    });

    test('filters logs below configured level', () async {
      final adapter = MockWebSocketAdapter();
      final events = <DartvexLogEvent>[];
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
          logLevel: DartvexLogLevel.warn,
          logger: events.add,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        events.where((event) => event.level == DartvexLogLevel.debug),
        isEmpty,
      );

      client.dispose();
    });

    test('emits websocket warning logs through configured logger', () {
      final adapter = MockWebSocketAdapter();
      final events = <DartvexLogEvent>[];
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
        logLevel: DartvexLogLevel.warn,
        logger: events.add,
      );

      unawaited(manager.start());
      final transition = Transition(
        startVersion: const StateVersion.initial(),
        endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
        modifications: const <StateModification>[
          QueryUpdated(queryId: 1, value: 'hello'),
        ],
        clientClockSkew: 0,
        serverTs: (DateTime.now().millisecondsSinceEpoch.toDouble() - 21000) *
            1000000,
      );
      adapter.pushServerMessage(transition.toJson());

      return Future<void>.delayed(const Duration(milliseconds: 20), () async {
        expect(events, hasLength(1));
        expect(events.single.level, DartvexLogLevel.warn);
        expect(events.single.tag, 'transport.ws');
        await manager.dispose();
      });
    });

    test('storage logs can use a caller log source', () async {
      final events = <DartvexLogEvent>[];
      final caller = _FakeLoggedCaller(events.add);
      caller.mutations['files:generateUploadUrl'] =
          (_) => 'https://upload.convex.cloud/abc123';
      caller.queries['files:getUrl'] =
          (_) => 'https://cdn.convex.cloud/file/kg2abc123';

      final storage = ConvexStorage(caller);

      await storage.getFileUrl(
        getUrlAction: 'files:getUrl',
        storageId: 'kg2abc123',
      );

      expect(events, isNotEmpty);
      expect(events.last.tag, 'storage');
    });

    test('auth logging does not expose token values', () async {
      final adapter = MockWebSocketAdapter();
      final events = <DartvexLogEvent>[];
      final provider = _FakeAuthProvider(
        token: 'secret-token',
        cachedToken: 'cached-secret-token',
      );
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
          logLevel: DartvexLogLevel.debug,
          logger: events.add,
        ),
      );
      final authClient = client.withAuth<_FakeSession>(provider);

      await authClient.login();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final joined = events
          .map((event) => '${event.message} ${event.data} ${event.error ?? ''}')
          .join('\n');
      expect(joined.contains('secret-token'), isFalse);
      expect(joined.contains('cached-secret-token'), isFalse);

      authClient.dispose();
    });

    test('request failure logging does not expose errorData or logLines',
        () async {
      final adapter = MockWebSocketAdapter();
      final events = <DartvexLogEvent>[];
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
          logLevel: DartvexLogLevel.error,
          logger: events.add,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      final future = client.mutate(
        'messages:send',
        const <String, dynamic>{'body': 'hello'},
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final mutation = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Mutation')
          .single;
      adapter.pushServerMessage(
        MutationResponse(
          requestId: mutation['requestId'] as int,
          success: false,
          errorMessage: 'Mutation failed',
          errorData: const <String, dynamic>{'secret': 'payload'},
          logLines: const <String>['secret log line'],
        ).toJson(),
      );

      await expectLater(
        future,
        throwsA(
          isA<ConvexException>().having(
            (error) => error.data,
            'data',
            const <String, dynamic>{'secret': 'payload'},
          ),
        ),
      );
      final failureLog = events.singleWhere(
        (event) => event.message == 'Mutation failed',
      );
      expect(
        failureLog.error,
        isA<ConvexException>()
            .having((error) => error.data, 'data', isNull)
            .having((error) => error.logLines, 'logLines', isEmpty),
      );
      expect(
          '${failureLog.error} ${failureLog.data}', isNot(contains('secret')));

      client.dispose();
    });
  });
}

class _FakeLoggedCaller implements ConvexFunctionCaller, DartvexLogSource {
  _FakeLoggedCaller(this.logger);

  final Map<String, dynamic Function(Map<String, dynamic>)> mutations =
      <String, dynamic Function(Map<String, dynamic>)>{};
  final Map<String, dynamic Function(Map<String, dynamic>)> queries =
      <String, dynamic Function(Map<String, dynamic>)>{};

  @override
  final DartvexLogLevel logLevel = DartvexLogLevel.debug;

  @override
  final DartvexLogger logger;

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    return mutations[name]!(args);
  }

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    return queries[name]!(args);
  }

  @override
  Future<T> queryOnce<T>(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final result = await query(name, args);
    return result as T;
  }

  @override
  ConvexSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    throw UnimplementedError();
  }
}

class _FakeSession {
  const _FakeSession(this.token);

  final String token;
}

class _FakeAuthProvider implements AuthProvider<_FakeSession> {
  _FakeAuthProvider({
    required this.token,
    required this.cachedToken,
  });

  final String token;
  final String cachedToken;

  @override
  String extractIdToken(_FakeSession authResult) => authResult.token;

  @override
  Future<_FakeSession> login({
    required void Function(String? token) onIdToken,
  }) async {
    onIdToken(token);
    return _FakeSession(token);
  }

  @override
  Future<_FakeSession> loginFromCache({
    required void Function(String? token) onIdToken,
  }) async {
    onIdToken(cachedToken);
    return _FakeSession(cachedToken);
  }

  @override
  Future<void> logout() async {}
}
