import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers/fake_runtime_client.dart';

void main() {
  Widget buildPaginated({
    required FakeRuntimeClient client,
    required void Function(List<Map<String, dynamic>>, PaginationStatus)
        onBuild,
    String query = 'items:list',
    Map<String, dynamic>? args,
    int pageSize = 2,
  }) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ConvexProvider(
        client: client,
        child: PaginatedQueryBuilder<Map<String, dynamic>>(
          query: query,
          args: args,
          pageSize: pageSize,
          fromJson: (json) => json,
          builder: (context, items, loadMore, status) {
            onBuild(items, status);
            return GestureDetector(
              onTap: loadMore,
              child: Text('status:$status items:${items.length}'),
            );
          },
        ),
      ),
    );
  }

  testWidgets('starts in loading state', (tester) async {
    final client = FakeRuntimeClient(
      initialConnectionState: ConvexConnectionState.connected,
    );
    PaginationStatus? capturedStatus;

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        onBuild: (_, status) => capturedStatus = status,
      ),
    );

    expect(capturedStatus, PaginationStatus.loading);
  });

  testWidgets('loads first page on init', (tester) async {
    final client = FakeRuntimeClient(
      initialConnectionState: ConvexConnectionState.connected,
    );
    client.onQuery = (name, args) async {
      return <String, dynamic>{
        'page': <dynamic>[
          {'id': '1', 'name': 'Item 1'},
          {'id': '2', 'name': 'Item 2'},
        ],
        'continueCursor': 'cursor1',
        'isDone': false,
      };
    };

    List<Map<String, dynamic>>? capturedItems;
    PaginationStatus? capturedStatus;

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        onBuild: (items, status) {
          capturedItems = items;
          capturedStatus = status;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(capturedItems, hasLength(2));
    expect(capturedStatus, PaginationStatus.idle);
  });

  testWidgets('loadMore loads next page', (tester) async {
    final client = FakeRuntimeClient(
      initialConnectionState: ConvexConnectionState.connected,
    );
    var callCount = 0;
    client.onQuery = (name, args) async {
      callCount++;
      if (callCount == 1) {
        return <String, dynamic>{
          'page': <dynamic>[
            {'id': '1'},
          ],
          'continueCursor': 'c1',
          'isDone': false,
        };
      }
      return <String, dynamic>{
        'page': <dynamic>[
          {'id': '2'},
        ],
        'continueCursor': 'c2',
        'isDone': true,
      };
    };

    List<Map<String, dynamic>>? capturedItems;
    PaginationStatus? capturedStatus;

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        onBuild: (items, status) {
          capturedItems = items;
          capturedStatus = status;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(capturedItems, hasLength(1));
    expect(capturedStatus, PaginationStatus.idle);

    // Tap to trigger loadMore
    await tester.tap(find.byType(GestureDetector));
    await tester.pumpAndSettle();

    expect(capturedItems, hasLength(2));
    expect(capturedStatus, PaginationStatus.allLoaded);
  });

  testWidgets('shows allLoaded when isDone is true on first page',
      (tester) async {
    final client = FakeRuntimeClient(
      initialConnectionState: ConvexConnectionState.connected,
    );
    client.onQuery = (name, args) async {
      return <String, dynamic>{
        'page': <dynamic>[
          {'id': '1'},
        ],
        'continueCursor': null,
        'isDone': true,
      };
    };

    PaginationStatus? capturedStatus;

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        onBuild: (_, status) => capturedStatus = status,
      ),
    );
    await tester.pumpAndSettle();

    expect(capturedStatus, PaginationStatus.allLoaded);
  });

  testWidgets('handles errors', (tester) async {
    final client = FakeRuntimeClient(
      initialConnectionState: ConvexConnectionState.connected,
    );
    client.onQuery = (name, args) async {
      throw StateError('query failed');
    };

    PaginationStatus? capturedStatus;

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        onBuild: (_, status) => capturedStatus = status,
      ),
    );
    await tester.pumpAndSettle();

    expect(capturedStatus, PaginationStatus.error);
  });
}
