// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: type=lint, unused_element, unused_import, unused_local_variable

import '../runtime.dart';
import '../schema.dart';
import 'package:dartvex/dartvex.dart';

class TasksApi {
  const TasksApi(this._client);

  final ConvexFunctionCaller _client;

  Future<AdvanceTaskResult> advanceTask({required TasksId taskId}) async {
    final raw$ = await _client.mutate(
      'tasks:advanceTask',
      _encodeAdvanceTaskArgs((taskId: taskId)),
    );
    return _decodeAdvanceTaskResult(raw$);
  }

  Future<double> clearTasks() async {
    final raw$ = await _client.mutate(
      'tasks:clearTasks',
      const <String, dynamic>{},
    );
    return expectDouble(raw$, label: 'ClearTasksResult');
  }

  Future<TasksId> createTask({
    required String? assignee,
    required double? dueAt,
    required double estimatePoints,
    required List<String> labels,
    required String priority,
    required String? summary,
    required String title,
  }) async {
    final raw$ = await _client.mutate(
      'tasks:createTask',
      _encodeCreateTaskArgs((
        assignee: assignee,
        dueAt: dueAt,
        estimatePoints: estimatePoints,
        labels: labels,
        priority: priority,
        summary: summary,
        title: title,
      )),
    );
    return TasksId(expectString(raw$, label: 'CreateTaskResult'));
  }

  Future<List<ListBoardResultItem>> listBoard() async {
    final raw$ = await _client.query(
      'tasks:listBoard',
      const <String, dynamic>{},
    );
    return expectList(
      raw$,
      label: 'ListBoardResult',
    ).map((item) => _decodeListBoardResultItem(item)).toList();
  }

  TypedConvexSubscription<List<ListBoardResultItem>> listBoardSubscribe() {
    final subscription$ = _client.subscribe(
      'tasks:listBoard',
      const <String, dynamic>{},
    );
    final typedStream$ = subscription$.stream.map((event) {
      switch (event) {
        case QuerySuccess(:final value):
          return TypedQuerySuccess<List<ListBoardResultItem>>(
            expectList(
              value,
              label: 'ListBoardResult',
            ).map((item) => _decodeListBoardResultItem(item)).toList(),
          );
        case QueryLoading(:final hasPendingWrites):
          return TypedQueryLoading<List<ListBoardResultItem>>(
            hasPendingWrites: hasPendingWrites,
          );
        case QueryError(:final message, :final data, :final logLines):
          return TypedQueryError<List<ListBoardResultItem>>(
            message,
            data: data,
            logLines: logLines,
          );
      }
    });
    return TypedConvexSubscription<List<ListBoardResultItem>>(
      subscription$,
      typedStream$,
    );
  }

  Future<double> seedBoard() async {
    final raw$ = await _client.mutate(
      'tasks:seedBoard',
      const <String, dynamic>{},
    );
    return expectDouble(raw$, label: 'SeedBoardResult');
  }
}

typedef AdvanceTaskResult = ({String status, TasksId taskId});

Map<String, dynamic> _encodeAdvanceTaskResult(AdvanceTaskResult value$) {
  final (status: status, taskId: taskId) = value$;
  return <String, dynamic>{'status': status, 'taskId': taskId.value};
}

AdvanceTaskResult _decodeAdvanceTaskResult(dynamic raw) {
  final map = expectMap(raw, label: 'AdvanceTaskResult');
  if (!map.containsKey('status')) {
    throw FormatException(
      'Missing required field "status" for AdvanceTaskResult',
    );
  }
  if (!map.containsKey('taskId')) {
    throw FormatException(
      'Missing required field "taskId" for AdvanceTaskResult',
    );
  }
  return (
    status: expectString(map['status'], label: 'AdvanceTaskResultStatus'),
    taskId: TasksId(
      expectString(map['taskId'], label: 'AdvanceTaskResultTaskId'),
    ),
  );
}

typedef AdvanceTaskArgs = ({TasksId taskId});

Map<String, dynamic> _encodeAdvanceTaskArgs(AdvanceTaskArgs value$) {
  final (taskId: taskId) = value$;
  return <String, dynamic>{'taskId': taskId.value};
}

AdvanceTaskArgs _decodeAdvanceTaskArgs(dynamic raw) {
  final map = expectMap(raw, label: 'AdvanceTaskArgs');
  if (!map.containsKey('taskId')) {
    throw FormatException(
      'Missing required field "taskId" for AdvanceTaskArgs',
    );
  }
  return (
    taskId: TasksId(
      expectString(map['taskId'], label: 'AdvanceTaskArgsTaskId'),
    ),
  );
}

typedef CreateTaskArgs = ({
  String? assignee,
  double? dueAt,
  double estimatePoints,
  List<String> labels,
  String priority,
  String? summary,
  String title,
});

Map<String, dynamic> _encodeCreateTaskArgs(CreateTaskArgs value$) {
  final (
    assignee: assignee,
    dueAt: dueAt,
    estimatePoints: estimatePoints,
    labels: labels,
    priority: priority,
    summary: summary,
    title: title,
  ) = value$;
  return <String, dynamic>{
    'assignee': assignee,
    'dueAt': dueAt,
    'estimatePoints': estimatePoints,
    'labels': labels.map((item) => item).toList(),
    'priority': priority,
    'summary': summary,
    'title': title,
  };
}

CreateTaskArgs _decodeCreateTaskArgs(dynamic raw) {
  final map = expectMap(raw, label: 'CreateTaskArgs');
  if (!map.containsKey('assignee')) {
    throw FormatException(
      'Missing required field "assignee" for CreateTaskArgs',
    );
  }
  if (!map.containsKey('dueAt')) {
    throw FormatException('Missing required field "dueAt" for CreateTaskArgs');
  }
  if (!map.containsKey('estimatePoints')) {
    throw FormatException(
      'Missing required field "estimatePoints" for CreateTaskArgs',
    );
  }
  if (!map.containsKey('labels')) {
    throw FormatException('Missing required field "labels" for CreateTaskArgs');
  }
  if (!map.containsKey('priority')) {
    throw FormatException(
      'Missing required field "priority" for CreateTaskArgs',
    );
  }
  if (!map.containsKey('summary')) {
    throw FormatException(
      'Missing required field "summary" for CreateTaskArgs',
    );
  }
  if (!map.containsKey('title')) {
    throw FormatException('Missing required field "title" for CreateTaskArgs');
  }
  return (
    assignee: map['assignee'] == null
        ? null
        : expectString(map['assignee'], label: 'CreateTaskArgsAssignee'),
    dueAt: map['dueAt'] == null
        ? null
        : expectDouble(map['dueAt'], label: 'CreateTaskArgsDueAt'),
    estimatePoints: expectDouble(
      map['estimatePoints'],
      label: 'CreateTaskArgsEstimatePoints',
    ),
    labels: expectList(map['labels'], label: 'CreateTaskArgsLabels')
        .map((item) => expectString(item, label: 'CreateTaskArgsLabelsItem'))
        .toList(),
    priority: expectString(map['priority'], label: 'CreateTaskArgsPriority'),
    summary: map['summary'] == null
        ? null
        : expectString(map['summary'], label: 'CreateTaskArgsSummary'),
    title: expectString(map['title'], label: 'CreateTaskArgsTitle'),
  );
}

typedef ListBoardResultItem = ({
  double creationTime,
  TasksId id,
  String? assignee,
  double? dueAt,
  double estimatePoints,
  List<String> labels,
  String priority,
  String status,
  String? summary,
  String title,
});

Map<String, dynamic> _encodeListBoardResultItem(ListBoardResultItem value$) {
  final (
    creationTime: creationTime,
    id: id,
    assignee: assignee,
    dueAt: dueAt,
    estimatePoints: estimatePoints,
    labels: labels,
    priority: priority,
    status: status,
    summary: summary,
    title: title,
  ) = value$;
  return <String, dynamic>{
    '_creationTime': creationTime,
    '_id': id.value,
    'assignee': assignee,
    'dueAt': dueAt,
    'estimatePoints': estimatePoints,
    'labels': labels.map((item) => item).toList(),
    'priority': priority,
    'status': status,
    'summary': summary,
    'title': title,
  };
}

ListBoardResultItem _decodeListBoardResultItem(dynamic raw) {
  final map = expectMap(raw, label: 'ListBoardResultItem');
  if (!map.containsKey('_creationTime')) {
    throw FormatException(
      'Missing required field "_creationTime" for ListBoardResultItem',
    );
  }
  if (!map.containsKey('_id')) {
    throw FormatException(
      'Missing required field "_id" for ListBoardResultItem',
    );
  }
  if (!map.containsKey('assignee')) {
    throw FormatException(
      'Missing required field "assignee" for ListBoardResultItem',
    );
  }
  if (!map.containsKey('dueAt')) {
    throw FormatException(
      'Missing required field "dueAt" for ListBoardResultItem',
    );
  }
  if (!map.containsKey('estimatePoints')) {
    throw FormatException(
      'Missing required field "estimatePoints" for ListBoardResultItem',
    );
  }
  if (!map.containsKey('labels')) {
    throw FormatException(
      'Missing required field "labels" for ListBoardResultItem',
    );
  }
  if (!map.containsKey('priority')) {
    throw FormatException(
      'Missing required field "priority" for ListBoardResultItem',
    );
  }
  if (!map.containsKey('status')) {
    throw FormatException(
      'Missing required field "status" for ListBoardResultItem',
    );
  }
  if (!map.containsKey('summary')) {
    throw FormatException(
      'Missing required field "summary" for ListBoardResultItem',
    );
  }
  if (!map.containsKey('title')) {
    throw FormatException(
      'Missing required field "title" for ListBoardResultItem',
    );
  }
  return (
    creationTime: expectDouble(
      map['_creationTime'],
      label: 'ListBoardResultItemCreationTime',
    ),
    id: TasksId(expectString(map['_id'], label: 'ListBoardResultItemId')),
    assignee: map['assignee'] == null
        ? null
        : expectString(map['assignee'], label: 'ListBoardResultItemAssignee'),
    dueAt: map['dueAt'] == null
        ? null
        : expectDouble(map['dueAt'], label: 'ListBoardResultItemDueAt'),
    estimatePoints: expectDouble(
      map['estimatePoints'],
      label: 'ListBoardResultItemEstimatePoints',
    ),
    labels: expectList(map['labels'], label: 'ListBoardResultItemLabels')
        .map(
          (item) => expectString(item, label: 'ListBoardResultItemLabelsItem'),
        )
        .toList(),
    priority: expectString(
      map['priority'],
      label: 'ListBoardResultItemPriority',
    ),
    status: expectString(map['status'], label: 'ListBoardResultItemStatus'),
    summary: map['summary'] == null
        ? null
        : expectString(map['summary'], label: 'ListBoardResultItemSummary'),
    title: expectString(map['title'], label: 'ListBoardResultItemTitle'),
  );
}
