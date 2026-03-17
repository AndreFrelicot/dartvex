// GENERATED CODE - DO NOT MODIFY BY HAND.

import './modules/demo.dart';
import './modules/messages.dart';
import './modules/tasks.dart';
import './runtime.dart';
import './schema.dart';
import 'package:dartvex/dartvex.dart';

export 'runtime.dart';
export 'schema.dart';

class ConvexApi {
  const ConvexApi(this._client);

  final ConvexClient _client;

  DemoApi get demo => DemoApi(_client);
  MessagesApi get messages => MessagesApi(_client);
  TasksApi get tasks => TasksApi(_client);
}
