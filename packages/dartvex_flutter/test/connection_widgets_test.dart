import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers/fake_runtime_client.dart';

void main() {
  Widget wrapWithProvider({
    required FakeRuntimeClient client,
    required Widget child,
  }) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ConvexProvider(client: client, child: child),
    );
  }

  testWidgets('ConvexConnectionBuilder renders current and updated states', (
    tester,
  ) async {
    final client = FakeRuntimeClient(
      initialConnectionState: ConvexConnectionState.disconnected,
    );

    await tester.pumpWidget(
      wrapWithProvider(
        client: client,
        child: ConvexConnectionBuilder(
          builder: (context, state) => Text(state.name),
        ),
      ),
    );

    expect(find.text('disconnected'), findsOneWidget);

    client.emitConnectionState(ConvexConnectionState.connected);
    await tester.pump();

    expect(find.text('connected'), findsOneWidget);
  });

  testWidgets('ConvexConnectionIndicator switches by connection state', (
    tester,
  ) async {
    final client = FakeRuntimeClient(
      initialConnectionState: ConvexConnectionState.connecting,
    );

    await tester.pumpWidget(
      wrapWithProvider(
        client: client,
        child: ConvexConnectionIndicator(
          connectedBuilder: (context) => const Text('online'),
          connectingBuilder: (context) => const Text('syncing'),
          disconnectedBuilder: (context) => const Text('offline'),
        ),
      ),
    );

    expect(find.text('syncing'), findsOneWidget);

    client.emitConnectionState(ConvexConnectionState.connected);
    await tester.pump();
    expect(find.text('online'), findsOneWidget);

    client.emitConnectionState(ConvexConnectionState.disconnected);
    await tester.pump();
    expect(find.text('offline'), findsOneWidget);
  });

  testWidgets('ConvexAuthRefreshingBuilder reflects the refreshing state', (
    tester,
  ) async {
    final client = FakeRuntimeClient();

    await tester.pumpWidget(
      wrapWithProvider(
        client: client,
        child: ConvexAuthRefreshingBuilder(
          builder: (context, isRefreshing) =>
              Text(isRefreshing ? 'refreshing' : 'idle'),
        ),
      ),
    );

    expect(find.text('idle'), findsOneWidget);

    client.emitAuthRefreshing(true);
    await tester.pump();
    expect(find.text('refreshing'), findsOneWidget);

    client.emitAuthRefreshing(false);
    await tester.pump();
    expect(find.text('idle'), findsOneWidget);
  });

  testWidgets('ConvexConnectionStatusBuilder renders rich status updates', (
    tester,
  ) async {
    final client = FakeRuntimeClient(
      initialConnectionState: ConvexConnectionState.connecting,
    );

    await tester.pumpWidget(
      wrapWithProvider(
        client: client,
        child: ConvexConnectionStatusBuilder(
          builder: (context, status) => Text(
            'loading=${status.isLoading} '
            'retries=${status.connectionRetries} '
            'inflight=${status.inflightMutations}',
          ),
        ),
      ),
    );

    // Derived from the coarse connecting state: loading, no retries/inflight.
    expect(find.text('loading=true retries=0 inflight=0'), findsOneWidget);

    client.emitConnectionStatus(
      const ConnectionStatus(
        state: ConvexConnectionState.reconnecting,
        isWebSocketConnected: false,
        isConnected: false,
        hasEverConnected: true,
        connectionCount: 2,
        connectionRetries: 3,
        inflightMutations: 1,
        inflightActions: 0,
        timeOfOldestInflightRequest: null,
        hasSyncedPastLastReconnect: false,
      ),
    );
    await tester.pump();

    expect(find.text('loading=true retries=3 inflight=1'), findsOneWidget);
  });
}
