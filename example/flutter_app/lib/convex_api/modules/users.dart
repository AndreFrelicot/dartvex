// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: type=lint, unused_element, unused_import, unused_local_variable

import '../runtime.dart';
import '../schema.dart';
import 'package:dartvex/dartvex.dart';

class UsersApi {
  const UsersApi(this._client);

  final ConvexFunctionCaller _client;

  Future<ViewerResult?> viewer() async {
    final raw$ = await _client.query('users:viewer', const <String, dynamic>{});
    return raw$ == null ? null : _decodeViewerResult(raw$);
  }

  TypedConvexSubscription<ViewerResult?> viewerSubscribe() {
    final subscription$ = _client.subscribe(
      'users:viewer',
      const <String, dynamic>{},
    );
    return TypedConvexSubscription<ViewerResult?>(
      subscription$,
      subscription$.stream.map(
        (event$) => typedQueryResult<ViewerResult?>(
          event$,
          (raw$) => raw$ == null ? null : _decodeViewerResult(raw$),
          'users:viewer',
        ),
      ),
    );
  }
}

typedef ViewerResult = ({
  double creationTime,
  String createdVia,
  UsersId userId,
});

Map<String, dynamic> _encodeViewerResult(ViewerResult value$) {
  final (creationTime: creationTime, createdVia: createdVia, userId: userId) =
      value$;
  return <String, dynamic>{
    '_creationTime': creationTime,
    'createdVia': createdVia,
    'userId': userId.value,
  };
}

ViewerResult _decodeViewerResult(dynamic raw) {
  final map = expectMap(raw, label: 'ViewerResult');
  if (!map.containsKey('_creationTime')) {
    throw FormatException(
      'Missing required field "_creationTime" for ViewerResult',
    );
  }
  if (!map.containsKey('createdVia')) {
    throw FormatException(
      'Missing required field "createdVia" for ViewerResult',
    );
  }
  if (!map.containsKey('userId')) {
    throw FormatException('Missing required field "userId" for ViewerResult');
  }
  return (
    creationTime: expectDouble(
      map['_creationTime'],
      label: 'ViewerResultCreationTime',
    ),
    createdVia: expectString(
      map['createdVia'],
      label: 'ViewerResultCreatedVia',
    ),
    userId: UsersId(expectString(map['userId'], label: 'ViewerResultUserId')),
  );
}
