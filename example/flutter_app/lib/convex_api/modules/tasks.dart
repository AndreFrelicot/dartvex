// GENERATED CODE - DO NOT MODIFY BY HAND.

import '../runtime.dart';
import '../schema.dart';
import 'package:dartvex/dartvex.dart';

class TasksApi {
  const TasksApi(this._client);

  final ConvexClient _client;

  Future<AdvanceTaskResult> advancetask({required TasksId taskid}) async {
    final raw = await _client.mutate(
      'tasks:advanceTask',
      _encodeAdvanceTaskArgs((taskid: taskid)),
    );
    return _decodeAdvanceTaskResult(raw);
  }

  Future<TasksId> createtask({
    required String? assignee,
    required double? dueat,
    required double estimatepoints,
    required List<String> labels,
    required String priority,
    required String? summary,
    required String title,
  }) async {
    final raw = await _client.mutate(
      'tasks:createTask',
      _encodeCreateTaskArgs((
        assignee: assignee,
        dueat: dueat,
        estimatepoints: estimatepoints,
        labels: labels,
        priority: priority,
        summary: summary,
        title: title,
      )),
    );
    return TasksId(expectString(raw, label: 'CreateTaskResult'));
  }

  Future<List<ListBoardResultItem>> listboard() async {
    final raw = await _client.query(
      'tasks:listBoard',
      const <String, dynamic>{},
    );
    return expectList(
      raw,
      label: 'ListBoardResult',
    ).map((item) => _decodeListBoardResultItem(item)).toList();
  }

  TypedConvexSubscription<List<ListBoardResultItem>> listboardSubscribe() {
    final subscription = _client.subscribe(
      'tasks:listBoard',
      const <String, dynamic>{},
    );
    final typedStream = subscription.stream.map(
      (event) => switch (event) {
        QuerySuccess(:final value) =>
          TypedQuerySuccess<List<ListBoardResultItem>>(
            expectList(
              value,
              label: 'ListBoardResult',
            ).map((item) => _decodeListBoardResultItem(item)).toList(),
          ),
        QueryError(:final message) =>
          TypedQueryError<List<ListBoardResultItem>>(message),
      },
    );
    return TypedConvexSubscription<List<ListBoardResultItem>>(
      subscription,
      typedStream,
    );
  }

  Future<double> seedboard() async {
    final raw = await _client.mutate(
      'tasks:seedBoard',
      const <String, dynamic>{},
    );
    return expectDouble(raw, label: 'SeedBoardResult');
  }

  Future<double> clearboard() async {
    final raw = await _client.mutate(
      'tasks:clearTasks',
      const <String, dynamic>{},
    );
    return expectDouble(raw, label: 'ClearTasksResult');
  }
}

typedef AdvanceTaskResult = ({String status, TasksId taskid});

Map<String, dynamic> _encodeAdvanceTaskResult(AdvanceTaskResult value) {
  final (status: status, taskid: taskid) = value;
  return <String, dynamic>{'status': status, 'taskId': taskid.value};
}

AdvanceTaskResult _decodeAdvanceTaskResult(dynamic raw) {
  final map = expectMap(raw, label: 'AdvanceTaskResult');
  return (
    status: expectString(map['status'], label: 'AdvanceTaskResultStatus'),
    taskid: TasksId(
      expectString(map['taskId'], label: 'AdvanceTaskResultTaskId'),
    ),
  );
}

typedef AdvanceTaskArgs = ({TasksId taskid});

Map<String, dynamic> _encodeAdvanceTaskArgs(AdvanceTaskArgs value) {
  final (taskid: taskid) = value;
  return <String, dynamic>{'taskId': taskid.value};
}

AdvanceTaskArgs _decodeAdvanceTaskArgs(dynamic raw) {
  final map = expectMap(raw, label: 'AdvanceTaskArgs');
  return (
    taskid: TasksId(
      expectString(map['taskId'], label: 'AdvanceTaskArgsTaskId'),
    ),
  );
}

typedef CreateTaskArgs = ({
  String? assignee,
  double? dueat,
  double estimatepoints,
  List<String> labels,
  String priority,
  String? summary,
  String title,
});

Map<String, dynamic> _encodeCreateTaskArgs(CreateTaskArgs value) {
  final (
    assignee: assignee,
    dueat: dueat,
    estimatepoints: estimatepoints,
    labels: labels,
    priority: priority,
    summary: summary,
    title: title,
  ) = value;
  return <String, dynamic>{
    'assignee': assignee == null ? null : assignee,
    'dueAt': dueat == null ? null : dueat,
    'estimatePoints': estimatepoints,
    'labels': labels.map((item) => item).toList(),
    'priority': priority,
    'summary': summary == null ? null : summary,
    'title': title,
  };
}

CreateTaskArgs _decodeCreateTaskArgs(dynamic raw) {
  final map = expectMap(raw, label: 'CreateTaskArgs');
  return (
    assignee: map['assignee'] == null
        ? null
        : expectString(map['assignee'], label: 'CreateTaskArgsAssignee'),
    dueat: map['dueAt'] == null
        ? null
        : expectDouble(map['dueAt'], label: 'CreateTaskArgsDueAt'),
    estimatepoints: expectDouble(
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
  double creationtime,
  TasksId id,
  String? assignee,
  double? dueat,
  double estimatepoints,
  List<String> labels,
  String priority,
  String status,
  String? summary,
  String title,
});

Map<String, dynamic> _encodeListBoardResultItem(ListBoardResultItem value) {
  final (
    creationtime: creationtime,
    id: id,
    assignee: assignee,
    dueat: dueat,
    estimatepoints: estimatepoints,
    labels: labels,
    priority: priority,
    status: status,
    summary: summary,
    title: title,
  ) = value;
  return <String, dynamic>{
    '_creationTime': creationtime,
    '_id': id.value,
    'assignee': assignee == null ? null : assignee,
    'dueAt': dueat == null ? null : dueat,
    'estimatePoints': estimatepoints,
    'labels': labels.map((item) => item).toList(),
    'priority': priority,
    'status': status,
    'summary': summary == null ? null : summary,
    'title': title,
  };
}

ListBoardResultItem _decodeListBoardResultItem(dynamic raw) {
  final map = expectMap(raw, label: 'ListBoardResultItem');
  return (
    creationtime: expectDouble(
      map['_creationTime'],
      label: 'ListBoardResultItemCreationTime',
    ),
    id: TasksId(expectString(map['_id'], label: 'ListBoardResultItemId')),
    assignee: map['assignee'] == null
        ? null
        : expectString(map['assignee'], label: 'ListBoardResultItemAssignee'),
    dueat: map['dueAt'] == null
        ? null
        : expectDouble(map['dueAt'], label: 'ListBoardResultItemDueAt'),
    estimatepoints: expectDouble(
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
