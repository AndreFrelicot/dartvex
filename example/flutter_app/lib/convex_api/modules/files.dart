// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: type=lint, unused_element, unused_import, unused_local_variable

import '../runtime.dart';
import '../schema.dart';
import 'package:dartvex/dartvex.dart';

class FilesApi {
  const FilesApi(this._client);

  final ConvexFunctionCaller _client;

  Future<ImagesId> add({
    required String caption,
    required StorageId storageId,
    OptimisticUpdate? optimisticUpdate,
  }) async {
    final raw$ = await _client.mutate(
      'files:add',
      _encodeAddArgs((caption: caption, storageId: storageId)),
      optimisticUpdate,
    );
    return ImagesId(expectString(raw$, label: 'AddResult'));
  }

  Future<double> clear({OptimisticUpdate? optimisticUpdate}) async {
    final raw$ = await _client.mutate(
      'files:clear',
      const <String, dynamic>{},
      optimisticUpdate,
    );
    return expectDouble(raw$, label: 'ClearResult');
  }

  Future<String> generateUploadUrl({OptimisticUpdate? optimisticUpdate}) async {
    final raw$ = await _client.mutate(
      'files:generateUploadUrl',
      const <String, dynamic>{},
      optimisticUpdate,
    );
    return expectString(raw$, label: 'GenerateUploadUrlResult');
  }

  Future<String?> getUrl({required StorageId storageId}) async {
    final raw$ = await _client.query(
      'files:getUrl',
      _encodeGetUrlArgs((storageId: storageId)),
    );
    return raw$ == null ? null : expectString(raw$, label: 'GetUrlResult');
  }

  TypedConvexSubscription<String?> getUrlSubscribe({
    required StorageId storageId,
  }) {
    final subscription$ = _client.subscribe(
      'files:getUrl',
      _encodeGetUrlArgs((storageId: storageId)),
    );
    return TypedConvexSubscription<String?>(
      subscription$,
      subscription$.stream.map(
        (event$) => typedQueryResult<String?>(
          event$,
          (raw$) =>
              raw$ == null ? null : expectString(raw$, label: 'GetUrlResult'),
          'files:getUrl',
        ),
      ),
    );
  }

  Future<List<ListResultItem>> list() async {
    final raw$ = await _client.query('files:list', const <String, dynamic>{});
    return expectList(
      raw$,
      label: 'ListResult',
    ).map((item) => _decodeListResultItem(item)).toList();
  }

  TypedConvexSubscription<List<ListResultItem>> listSubscribe() {
    final subscription$ = _client.subscribe(
      'files:list',
      const <String, dynamic>{},
    );
    return TypedConvexSubscription<List<ListResultItem>>(
      subscription$,
      subscription$.stream.map(
        (event$) => typedQueryResult<List<ListResultItem>>(
          event$,
          (raw$) => expectList(
            raw$,
            label: 'ListResult',
          ).map((item) => _decodeListResultItem(item)).toList(),
          'files:list',
        ),
      ),
    );
  }
}

typedef AddArgs = ({String caption, StorageId storageId});

Map<String, dynamic> _encodeAddArgs(AddArgs value$) {
  final (caption: caption, storageId: storageId) = value$;
  return <String, dynamic>{'caption': caption, 'storageId': storageId.value};
}

AddArgs _decodeAddArgs(dynamic raw) {
  final map = expectMap(raw, label: 'AddArgs');
  if (!map.containsKey('caption')) {
    throw FormatException('Missing required field "caption" for AddArgs');
  }
  if (!map.containsKey('storageId')) {
    throw FormatException('Missing required field "storageId" for AddArgs');
  }
  return (
    caption: expectString(map['caption'], label: 'AddArgsCaption'),
    storageId: StorageId(
      expectString(map['storageId'], label: 'AddArgsStorageId'),
    ),
  );
}

typedef GetUrlArgs = ({StorageId storageId});

Map<String, dynamic> _encodeGetUrlArgs(GetUrlArgs value$) {
  final (storageId: storageId) = value$;
  return <String, dynamic>{'storageId': storageId.value};
}

GetUrlArgs _decodeGetUrlArgs(dynamic raw) {
  final map = expectMap(raw, label: 'GetUrlArgs');
  if (!map.containsKey('storageId')) {
    throw FormatException('Missing required field "storageId" for GetUrlArgs');
  }
  return (
    storageId: StorageId(
      expectString(map['storageId'], label: 'GetUrlArgsStorageId'),
    ),
  );
}

typedef ListResultItem = ({
  double creationTime,
  ImagesId id,
  String caption,
  StorageId storageId,
});

Map<String, dynamic> _encodeListResultItem(ListResultItem value$) {
  final (
    creationTime: creationTime,
    id: id,
    caption: caption,
    storageId: storageId,
  ) = value$;
  return <String, dynamic>{
    '_creationTime': creationTime,
    '_id': id.value,
    'caption': caption,
    'storageId': storageId.value,
  };
}

ListResultItem _decodeListResultItem(dynamic raw) {
  final map = expectMap(raw, label: 'ListResultItem');
  if (!map.containsKey('_creationTime')) {
    throw FormatException(
      'Missing required field "_creationTime" for ListResultItem',
    );
  }
  if (!map.containsKey('_id')) {
    throw FormatException('Missing required field "_id" for ListResultItem');
  }
  if (!map.containsKey('caption')) {
    throw FormatException(
      'Missing required field "caption" for ListResultItem',
    );
  }
  if (!map.containsKey('storageId')) {
    throw FormatException(
      'Missing required field "storageId" for ListResultItem',
    );
  }
  return (
    creationTime: expectDouble(
      map['_creationTime'],
      label: 'ListResultItemCreationTime',
    ),
    id: ImagesId(expectString(map['_id'], label: 'ListResultItemId')),
    caption: expectString(map['caption'], label: 'ListResultItemCaption'),
    storageId: StorageId(
      expectString(map['storageId'], label: 'ListResultItemStorageId'),
    ),
  );
}
