// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: type=lint, unused_element, unused_import, unused_local_variable

import '../runtime.dart';
import '../schema.dart';
import './admin/users.dart';
import 'package:dartvex/dartvex.dart';

class AdminApi {
  const AdminApi(this._client);

  final ConvexFunctionCaller _client;

  AdminUsersApi get users => AdminUsersApi(_client);
}
