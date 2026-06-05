// GENERATED CODE - DO NOT MODIFY BY HAND.

import '../runtime.dart';
import '../schema.dart';
import 'package:dartvex/dartvex.dart';

class MessagesApi {
  const MessagesApi(this._client);

  final ConvexFunctionCaller _client;

  Future<double> clearPublicMessages() async {
    final raw = await _client.mutate(
      'messages:clearPublicMessages',
      const <String, dynamic>{},
    );
    return expectDouble(raw, label: 'ClearPublicMessagesResult');
  }

  Future<List<ListPrivateResultItem>> listPrivate() async {
    final raw = await _client.query(
      'messages:listPrivate',
      const <String, dynamic>{},
    );
    return expectList(
      raw,
      label: 'ListPrivateResult',
    ).map((item) => _decodeListPrivateResultItem(item)).toList();
  }

  TypedConvexSubscription<List<ListPrivateResultItem>> listPrivateSubscribe() {
    final subscription = _client.subscribe(
      'messages:listPrivate',
      const <String, dynamic>{},
    );
    final typedStream = subscription.stream.map(
      (event) => switch (event) {
        QuerySuccess(:final value) =>
          TypedQuerySuccess<List<ListPrivateResultItem>>(
            expectList(
              value,
              label: 'ListPrivateResult',
            ).map((item) => _decodeListPrivateResultItem(item)).toList(),
          ),
        QueryLoading(:final hasPendingWrites) =>
          TypedQueryLoading<List<ListPrivateResultItem>>(
            hasPendingWrites: hasPendingWrites,
          ),
        QueryError(:final message, :final data, :final logLines) =>
          TypedQueryError<List<ListPrivateResultItem>>(
            message,
            data: data,
            logLines: logLines,
          ),
      },
    );
    return TypedConvexSubscription<List<ListPrivateResultItem>>(
      subscription,
      typedStream,
    );
  }

  Future<List<ListPublicResultItem>> listPublic() async {
    final raw = await _client.query(
      'messages:listPublic',
      const <String, dynamic>{},
    );
    return expectList(
      raw,
      label: 'ListPublicResult',
    ).map((item) => _decodeListPublicResultItem(item)).toList();
  }

  TypedConvexSubscription<List<ListPublicResultItem>> listPublicSubscribe() {
    final subscription = _client.subscribe(
      'messages:listPublic',
      const <String, dynamic>{},
    );
    final typedStream = subscription.stream.map(
      (event) => switch (event) {
        QuerySuccess(:final value) =>
          TypedQuerySuccess<List<ListPublicResultItem>>(
            expectList(
              value,
              label: 'ListPublicResult',
            ).map((item) => _decodeListPublicResultItem(item)).toList(),
          ),
        QueryLoading(:final hasPendingWrites) =>
          TypedQueryLoading<List<ListPublicResultItem>>(
            hasPendingWrites: hasPendingWrites,
          ),
        QueryError(:final message, :final data, :final logLines) =>
          TypedQueryError<List<ListPublicResultItem>>(
            message,
            data: data,
            logLines: logLines,
          ),
      },
    );
    return TypedConvexSubscription<List<ListPublicResultItem>>(
      subscription,
      typedStream,
    );
  }

  Future<PrivateMessagesId> sendPrivate({required String text}) async {
    final raw = await _client.mutate(
      'messages:sendPrivate',
      _encodeSendPrivateArgs((text: text)),
    );
    return PrivateMessagesId(expectString(raw, label: 'SendPrivateResult'));
  }

  Future<PublicMessagesId> sendPublic({
    required String author,
    required String text,
  }) async {
    final raw = await _client.mutate(
      'messages:sendPublic',
      _encodeSendPublicArgs((author: author, text: text)),
    );
    return PublicMessagesId(expectString(raw, label: 'SendPublicResult'));
  }
}

typedef ListPrivateResultItem = ({
  double creationTime,
  PrivateMessagesId id,
  String author,
  String text,
  String tokenIdentifier,
});

Map<String, dynamic> _encodeListPrivateResultItem(ListPrivateResultItem value) {
  final (
    creationTime: creationTime,
    id: id,
    author: author,
    text: text,
    tokenIdentifier: tokenIdentifier,
  ) = value;
  return <String, dynamic>{
    '_creationTime': creationTime,
    '_id': id.value,
    'author': author,
    'text': text,
    'tokenIdentifier': tokenIdentifier,
  };
}

ListPrivateResultItem _decodeListPrivateResultItem(dynamic raw) {
  final map = expectMap(raw, label: 'ListPrivateResultItem');
  return (
    creationTime: expectDouble(
      map['_creationTime'],
      label: 'ListPrivateResultItemCreationTime',
    ),
    id: PrivateMessagesId(
      expectString(map['_id'], label: 'ListPrivateResultItemId'),
    ),
    author: expectString(map['author'], label: 'ListPrivateResultItemAuthor'),
    text: expectString(map['text'], label: 'ListPrivateResultItemText'),
    tokenIdentifier: expectString(
      map['tokenIdentifier'],
      label: 'ListPrivateResultItemTokenIdentifier',
    ),
  );
}

typedef ListPublicResultItem = ({
  double creationTime,
  PublicMessagesId id,
  String author,
  String text,
});

Map<String, dynamic> _encodeListPublicResultItem(ListPublicResultItem value) {
  final (creationTime: creationTime, id: id, author: author, text: text) =
      value;
  return <String, dynamic>{
    '_creationTime': creationTime,
    '_id': id.value,
    'author': author,
    'text': text,
  };
}

ListPublicResultItem _decodeListPublicResultItem(dynamic raw) {
  final map = expectMap(raw, label: 'ListPublicResultItem');
  return (
    creationTime: expectDouble(
      map['_creationTime'],
      label: 'ListPublicResultItemCreationTime',
    ),
    id: PublicMessagesId(
      expectString(map['_id'], label: 'ListPublicResultItemId'),
    ),
    author: expectString(map['author'], label: 'ListPublicResultItemAuthor'),
    text: expectString(map['text'], label: 'ListPublicResultItemText'),
  );
}

typedef SendPrivateArgs = ({String text});

Map<String, dynamic> _encodeSendPrivateArgs(SendPrivateArgs value) {
  final (text: text) = value;
  return <String, dynamic>{'text': text};
}

SendPrivateArgs _decodeSendPrivateArgs(dynamic raw) {
  final map = expectMap(raw, label: 'SendPrivateArgs');
  return (text: expectString(map['text'], label: 'SendPrivateArgsText'));
}

typedef SendPublicArgs = ({String author, String text});

Map<String, dynamic> _encodeSendPublicArgs(SendPublicArgs value) {
  final (author: author, text: text) = value;
  return <String, dynamic>{'author': author, 'text': text};
}

SendPublicArgs _decodeSendPublicArgs(dynamic raw) {
  final map = expectMap(raw, label: 'SendPublicArgs');
  return (
    author: expectString(map['author'], label: 'SendPublicArgsAuthor'),
    text: expectString(map['text'], label: 'SendPublicArgsText'),
  );
}
