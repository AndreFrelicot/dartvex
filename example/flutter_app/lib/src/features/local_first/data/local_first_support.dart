import 'package:dartvex_local/dartvex_local.dart';

import '../../../../convex_api/runtime.dart';
import '../../../../convex_api/schema.dart';
import '../../../../convex_api/modules/messages.dart' as messages_api;
import '../../../../convex_api/modules/tasks.dart' as tasks_api;

List<messages_api.ListPublicResultItem> decodeLocalPublicMessages(dynamic raw) {
  return expectList(raw, label: 'ListPublicResult')
      .map((item) {
        final map = expectMap(item, label: 'ListPublicResultItem');
        return (
          creationtime: expectDouble(
            map['_creationTime'],
            label: 'ListPublicResultItemCreationTime',
          ),
          id: PublicMessagesId(
            expectString(map['_id'], label: 'ListPublicResultItemId'),
          ),
          author: expectString(
            map['author'],
            label: 'ListPublicResultItemAuthor',
          ),
          text: expectString(map['text'], label: 'ListPublicResultItemText'),
        );
      })
      .toList(growable: false);
}

List<tasks_api.ListBoardResultItem> decodeLocalTasks(dynamic raw) {
  return expectList(raw, label: 'ListBoardResult')
      .map((item) {
        final map = expectMap(item, label: 'ListBoardResultItem');
        return (
          creationtime: expectDouble(
            map['_creationTime'],
            label: 'ListBoardResultItemCreationTime',
          ),
          id: TasksId(expectString(map['_id'], label: 'ListBoardResultItemId')),
          assignee: map['assignee'] == null
              ? null
              : expectString(
                  map['assignee'],
                  label: 'ListBoardResultItemAssignee',
                ),
          dueat: map['dueAt'] == null
              ? null
              : expectDouble(map['dueAt'], label: 'ListBoardResultItemDueAt'),
          estimatepoints: expectDouble(
            map['estimatePoints'],
            label: 'ListBoardResultItemEstimatePoints',
          ),
          labels: expectList(map['labels'], label: 'ListBoardResultItemLabels')
              .map(
                (entry) =>
                    expectString(entry, label: 'ListBoardResultItemLabelsItem'),
              )
              .toList(growable: false),
          priority: expectString(
            map['priority'],
            label: 'ListBoardResultItemPriority',
          ),
          status: expectString(
            map['status'],
            label: 'ListBoardResultItemStatus',
          ),
          summary: map['summary'] == null
              ? null
              : expectString(
                  map['summary'],
                  label: 'ListBoardResultItemSummary',
                ),
          title: expectString(map['title'], label: 'ListBoardResultItemTitle'),
        );
      })
      .toList(growable: false);
}

List<LocalMutationHandler> buildLocalFirstHandlers() {
  return const <LocalMutationHandler>[
    _SendPublicMessageHandler(),
    _CreateTaskHandler(),
    _AdvanceTaskHandler(),
  ];
}

String nextTaskStatus(String current) {
  return switch (current) {
    'backlog' => 'in_progress',
    'in_progress' => 'done',
    _ => 'backlog',
  };
}

class _SendPublicMessageHandler extends LocalMutationHandler {
  const _SendPublicMessageHandler();

  @override
  String get mutationName => 'messages:sendPublic';

  @override
  List<LocalMutationPatch> buildPatches(
    Map<String, dynamic> args,
    LocalMutationContext context,
  ) {
    return <LocalMutationPatch>[
      LocalMutationPatch(
        target: const LocalQueryDescriptor('messages:listPublic'),
        apply: (currentValue) {
          final items = currentValue is List
              ? List<dynamic>.from(currentValue)
              : <dynamic>[];
          items.insert(0, <String, dynamic>{
            '_id': context.operationId,
            '_creationTime': context.queuedAt.millisecondsSinceEpoch.toDouble(),
            'author': args['author'],
            'text': args['text'],
          });
          return items;
        },
      ),
    ];
  }
}

class _CreateTaskHandler extends LocalMutationHandler {
  const _CreateTaskHandler();

  @override
  String get mutationName => 'tasks:createTask';

  @override
  List<LocalMutationPatch> buildPatches(
    Map<String, dynamic> args,
    LocalMutationContext context,
  ) {
    return <LocalMutationPatch>[
      LocalMutationPatch(
        target: const LocalQueryDescriptor('tasks:listBoard'),
        apply: (currentValue) {
          final items = currentValue is List
              ? List<dynamic>.from(currentValue)
              : <dynamic>[];
          items.insert(0, <String, dynamic>{
            '_id': context.operationId,
            '_creationTime': context.queuedAt.millisecondsSinceEpoch.toDouble(),
            'assignee': args['assignee'],
            'dueAt': args['dueAt'],
            'estimatePoints': args['estimatePoints'],
            'labels': args['labels'] ?? const <String>[],
            'priority': args['priority'] ?? 'medium',
            'status': 'backlog',
            'summary': args['summary'],
            'title': args['title'],
          });
          return items;
        },
      ),
    ];
  }
}

class _AdvanceTaskHandler extends LocalMutationHandler {
  const _AdvanceTaskHandler();

  @override
  String get mutationName => 'tasks:advanceTask';

  @override
  List<LocalMutationPatch> buildPatches(
    Map<String, dynamic> args,
    LocalMutationContext context,
  ) {
    return <LocalMutationPatch>[
      LocalMutationPatch(
        target: const LocalQueryDescriptor('tasks:listBoard'),
        apply: (currentValue) {
          if (currentValue is! List) {
            return currentValue;
          }
          final items = currentValue
              .map(
                (entry) =>
                    entry is Map ? Map<String, dynamic>.from(entry) : entry,
              )
              .toList(growable: false);
          final taskId = args['taskId'];
          for (final entry in items.whereType<Map<String, dynamic>>()) {
            if (entry['_id'] == taskId) {
              entry['status'] = nextTaskStatus(
                expectString(entry['status'], label: 'TaskStatus'),
              );
              break;
            }
          }
          return items;
        },
      ),
    ];
  }
}
