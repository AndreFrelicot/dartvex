import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers/fake_runtime_client.dart';

void main() {
  FakeRuntimeClient connectedClient() => FakeRuntimeClient(
    initialConnectionState: ConvexConnectionState.connected,
  );

  testWidgets('PaginatedQueryBuilder keeps loaded pages when a parent rebuild '
      'passes a new fromJson closure', (tester) async {
    final client = connectedClient();
    List<Map<String, dynamic>>? capturedItems;
    PaginationStatus? capturedStatus;

    Widget build() {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: ConvexProvider(
          client: client,
          child: PaginatedQueryBuilder<Map<String, dynamic>>(
            query: 'items:list',
            pageSize: 2,
            // A fresh closure per build, as in any inline call site.
            fromJson: (json) => json,
            builder: (context, items, loadMore, status) {
              capturedItems = items;
              capturedStatus = status;
              return Text('items:${items.length}');
            },
          ),
        ),
      );
    }

    await tester.pumpWidget(build());
    client.paginatedQueryCalls.single.query.emitPage(<dynamic>[
      <String, dynamic>{'id': '1'},
      <String, dynamic>{'id': '2'},
    ], status: ConvexPaginationStatus.canLoadMore);
    await tester.pump();
    expect(capturedItems, hasLength(2));

    // Parent rebuild with identical config but a new fromJson instance.
    await tester.pumpWidget(build());

    expect(
      client.paginatedQueryCalls,
      hasLength(1),
      reason: 'a parent rebuild must not reset the paginated query',
    );
    expect(capturedItems, hasLength(2));
    expect(capturedStatus, PaginationStatus.idle);
  });

  testWidgets(
    'PaginatedQueryBuilder re-maps current items when fromJson changes',
    (tester) async {
      final client = connectedClient();
      List<String>? capturedItems;

      Widget build(String Function(Map<String, dynamic>) fromJson) {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexProvider(
            client: client,
            child: PaginatedQueryBuilder<String>(
              query: 'items:list',
              pageSize: 2,
              fromJson: fromJson,
              builder: (context, items, loadMore, status) {
                capturedItems = items;
                return Text('items:${items.length}');
              },
            ),
          ),
        );
      }

      await tester.pumpWidget(build((json) => 'a:${json['id']}'));
      client.paginatedQueryCalls.single.query.emitPage(<dynamic>[
        <String, dynamic>{'id': '1'},
      ], status: ConvexPaginationStatus.canLoadMore);
      await tester.pump();
      expect(capturedItems, <String>['a:1']);

      await tester.pumpWidget(build((json) => 'b:${json['id']}'));

      expect(client.paginatedQueryCalls, hasLength(1));
      expect(
        capturedItems,
        <String>['b:1'],
        reason: 'a changed fromJson must re-map already-loaded items',
      );
    },
  );

  testWidgets(
    'ConvexQuery keeps its subscription when a parent rebuild passes a '
    'new decode closure',
    (tester) async {
      final client = connectedClient();
      ConvexQuerySnapshot<String>? capturedSnapshot;

      Widget build() {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexProvider(
            client: client,
            child: ConvexQuery<String>(
              query: 'messages:greeting',
              decode: (value) => value as String,
              builder: (context, snapshot) {
                capturedSnapshot = snapshot;
                return Text('data:${snapshot.data}');
              },
            ),
          ),
        );
      }

      await tester.pumpWidget(build());
      client.subscribeCalls.single.subscription.emitSuccess('hello');
      await tester.pump();
      expect(capturedSnapshot?.data, 'hello');

      await tester.pumpWidget(build());

      expect(
        client.subscribeCalls,
        hasLength(1),
        reason: 'a parent rebuild must not resubscribe the query',
      );
      expect(capturedSnapshot?.data, 'hello');
      expect(capturedSnapshot?.isRefreshing, isFalse);
    },
  );

  testWidgets('ConvexQuery re-decodes the current value when decode changes', (
    tester,
  ) async {
    final client = connectedClient();
    ConvexQuerySnapshot<String>? capturedSnapshot;

    Widget build(String Function(dynamic) decode) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: ConvexProvider(
          client: client,
          child: ConvexQuery<String>(
            query: 'messages:greeting',
            decode: decode,
            builder: (context, snapshot) {
              capturedSnapshot = snapshot;
              return Text('data:${snapshot.data}');
            },
          ),
        ),
      );
    }

    await tester.pumpWidget(build((value) => 'a:$value'));
    client.subscribeCalls.single.subscription.emitSuccess('x');
    await tester.pump();
    expect(capturedSnapshot?.data, 'a:x');

    await tester.pumpWidget(build((value) => 'b:$value'));

    expect(client.subscribeCalls, hasLength(1));
    expect(
      capturedSnapshot?.data,
      'b:x',
      reason: 'a changed decode must re-decode the current value',
    );
  });

  testWidgets(
    'ConvexMutation keeps its snapshot when a parent rebuild passes new '
    'decode and optimisticUpdate closures',
    (tester) async {
      final client = connectedClient();
      client.onMutate = (name, args) async => 'sent';
      ConvexRequestSnapshot<String>? capturedSnapshot;
      late ConvexRequestExecutor<String> capturedMutate;

      Widget build() {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexProvider(
            client: client,
            child: ConvexMutation<String>(
              mutation: 'messages:send',
              decode: (value) => value as String,
              optimisticUpdate: (store) {},
              builder: (context, mutate, snapshot) {
                capturedMutate = mutate;
                capturedSnapshot = snapshot;
                return const Text('mutation');
              },
            ),
          ),
        );
      }

      await tester.pumpWidget(build());
      await capturedMutate();
      await tester.pump();
      expect(capturedSnapshot?.data, 'sent');

      // Parent rebuild with identical config but new closure instances.
      await tester.pumpWidget(build());

      expect(
        capturedSnapshot?.data,
        'sent',
        reason: 'a parent rebuild must not wipe the request snapshot',
      );
      expect(capturedSnapshot?.hasData, isTrue);
    },
  );
}
