import 'dart:async';
import 'dart:convert';

import 'package:dartvex/dartvex.dart' as convex;
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:dartvex/src/transport/ws_interface.dart';
import 'package:dartvex_local/dartvex_local.dart';
import 'package:test/test.dart';

void main() {
  group('ConvexRemoteClientAdapter', () {
    Future<void> settle() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    test('seeds currentConnectionState from wrapped client', () async {
      final client = convex.ConvexClient(
        'https://demo.convex.cloud',
        config: const convex.ConvexClientConfig(connectImmediately: false),
      );
      final adapter = ConvexRemoteClientAdapter(client);

      expect(
        adapter.currentConnectionState,
        LocalRemoteConnectionState.disconnected,
      );

      adapter.dispose();
      client.dispose();
    });

    test('preserves remote query error data and log lines', () async {
      final socket = _MockWebSocketAdapter();
      final client = convex.ConvexClient(
        'https://demo.convex.cloud',
        config: convex.ConvexClientConfig(
          adapterFactory: (_) => socket,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      final adapter = ConvexRemoteClientAdapter(client, disposeClient: true);
      await settle();

      final subscription = adapter.subscribe('messages:list');
      final future = subscription.stream.first;
      await settle();

      final querySet = socket.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .last;
      final queryId = (((querySet['modifications'] as List<dynamic>).single
          as Map<String, dynamic>)['queryId']) as int;

      socket.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryFailed(
              queryId: queryId,
              errorMessage: 'not found',
              errorData: const <String, dynamic>{'code': 'missing'},
              logLines: const <String>['server log'],
            ),
          ],
        ).toJson(),
      );

      await expectLater(
        future,
        completion(
          isA<LocalRemoteQueryError>().having(
            (event) => event.error,
            'error',
            isA<convex.ConvexException>()
                .having((error) => error.message, 'message', 'not found')
                .having(
              (error) => error.data,
              'data',
              const <String, dynamic>{'code': 'missing'},
            ).having(
              (error) => error.logLines,
              'logLines',
              const <String>['server log'],
            ),
          ),
        ),
      );

      subscription.cancel();
      adapter.dispose();
    });
  });
}

class _MockWebSocketAdapter implements WebSocketAdapter {
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closeController =
      StreamController<WebSocketCloseEvent>.broadcast();

  final List<String> sentMessages = <String>[];
  bool _connected = false;

  @override
  Future<void> connect(String url) async {
    _connected = true;
  }

  @override
  void send(String message) {
    if (!_connected) {
      throw StateError('Mock socket is disconnected');
    }
    sentMessages.add(message);
  }

  List<Map<String, dynamic>> get decodedSentMessages {
    return sentMessages
        .map((message) => jsonDecode(message) as Map<String, dynamic>)
        .toList(growable: false);
  }

  void pushServerMessage(Map<String, dynamic> message) {
    _messagesController.add(jsonEncode(message));
  }

  @override
  Stream<String> get messages => _messagesController.stream;

  @override
  Stream<WebSocketCloseEvent> get closeEvents => _closeController.stream;

  @override
  Future<void> close() async {
    _connected = false;
    _closeController.add(const WebSocketCloseEvent());
  }

  @override
  bool get isConnected => _connected;
}
