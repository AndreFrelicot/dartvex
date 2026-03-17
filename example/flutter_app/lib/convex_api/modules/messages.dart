// GENERATED CODE - DO NOT MODIFY BY HAND.

import '../runtime.dart';
import '../schema.dart';
import 'package:dartvex/dartvex.dart';

class MessagesApi {
  const MessagesApi(this._client);

  final ConvexClient _client;

  Future<List<ListPrivateResultItem>> listprivate() async {
    final raw = await _client.query(
      'messages:listPrivate',
      const <String, dynamic>{},
    );
    return expectList(
      raw,
      label: 'ListPrivateResult',
    ).map((item) => _decodeListPrivateResultItem(item)).toList();
  }

  TypedConvexSubscription<List<ListPrivateResultItem>> listprivateSubscribe() {
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
        QueryError(:final message) =>
          TypedQueryError<List<ListPrivateResultItem>>(message),
      },
    );
    return TypedConvexSubscription<List<ListPrivateResultItem>>(
      subscription,
      typedStream,
    );
  }

  Future<List<ListPublicResultItem>> listpublic() async {
    final raw = await _client.query(
      'messages:listPublic',
      const <String, dynamic>{},
    );
    return expectList(
      raw,
      label: 'ListPublicResult',
    ).map((item) => _decodeListPublicResultItem(item)).toList();
  }

  TypedConvexSubscription<List<ListPublicResultItem>> listpublicSubscribe() {
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
        QueryError(:final message) =>
          TypedQueryError<List<ListPublicResultItem>>(message),
      },
    );
    return TypedConvexSubscription<List<ListPublicResultItem>>(
      subscription,
      typedStream,
    );
  }

  Future<PrivateMessagesId> sendprivate({required String text}) async {
    final raw = await _client.mutate(
      'messages:sendPrivate',
      _encodeSendPrivateArgs((text: text)),
    );
    return PrivateMessagesId(expectString(raw, label: 'SendPrivateResult'));
  }

  Future<PublicMessagesId> sendpublic({
    required String author,
    required String text,
  }) async {
    final raw = await _client.mutate(
      'messages:sendPublic',
      _encodeSendPublicArgs((author: author, text: text)),
    );
    return PublicMessagesId(expectString(raw, label: 'SendPublicResult'));
  }

  Future<double> clearpublic() async {
    final raw = await _client.mutate(
      'messages:clearPublicMessages',
      const <String, dynamic>{},
    );
    return expectDouble(raw, label: 'ClearPublicMessagesResult');
  }
}

typedef ListPrivateResultItem = ({
  double creationtime,
  PrivateMessagesId id,
  String author,
  String text,
  String tokenidentifier,
});

Map<String, dynamic> _encodeListPrivateResultItem(ListPrivateResultItem value) {
  final (
    creationtime: creationtime,
    id: id,
    author: author,
    text: text,
    tokenidentifier: tokenidentifier,
  ) = value;
  return <String, dynamic>{
    '_creationTime': creationtime,
    '_id': id.value,
    'author': author,
    'text': text,
    'tokenIdentifier': tokenidentifier,
  };
}

ListPrivateResultItem _decodeListPrivateResultItem(dynamic raw) {
  final map = expectMap(raw, label: 'ListPrivateResultItem');
  return (
    creationtime: expectDouble(
      map['_creationTime'],
      label: 'ListPrivateResultItemCreationTime',
    ),
    id: PrivateMessagesId(
      expectString(map['_id'], label: 'ListPrivateResultItemId'),
    ),
    author: expectString(map['author'], label: 'ListPrivateResultItemAuthor'),
    text: expectString(map['text'], label: 'ListPrivateResultItemText'),
    tokenidentifier: expectString(
      map['tokenIdentifier'],
      label: 'ListPrivateResultItemTokenIdentifier',
    ),
  );
}

typedef ListPublicResultItem = ({
  double creationtime,
  PublicMessagesId id,
  String author,
  String text,
});

Map<String, dynamic> _encodeListPublicResultItem(ListPublicResultItem value) {
  final (creationtime: creationtime, id: id, author: author, text: text) =
      value;
  return <String, dynamic>{
    '_creationTime': creationtime,
    '_id': id.value,
    'author': author,
    'text': text,
  };
}

ListPublicResultItem _decodeListPublicResultItem(dynamic raw) {
  final map = expectMap(raw, label: 'ListPublicResultItem');
  return (
    creationtime: expectDouble(
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
