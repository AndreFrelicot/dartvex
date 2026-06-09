// GENERATED CODE - DO NOT MODIFY BY HAND.

import '../runtime.dart';
import '../schema.dart';
import 'package:dartvex/dartvex.dart';

class MessagesApi {
  const MessagesApi(this._client);

  final ConvexFunctionCaller _client;

  Future<double> clearPrivate() async {
    final raw = await _client.mutate(
      'messages:clearPrivate',
      const <String, dynamic>{},
    );
    return expectDouble(raw, label: 'ClearPrivateResult');
  }

  Future<double> clearPublicMessages() async {
    final raw = await _client.mutate(
      'messages:clearPublicMessages',
      const <String, dynamic>{},
    );
    return expectDouble(raw, label: 'ClearPublicMessagesResult');
  }

  Future<double> countPublic() async {
    final raw = await _client.query(
      'messages:countPublic',
      const <String, dynamic>{},
    );
    return expectDouble(raw, label: 'CountPublicResult');
  }

  TypedConvexSubscription<double> countPublicSubscribe() {
    final subscription = _client.subscribe(
      'messages:countPublic',
      const <String, dynamic>{},
    );
    final typedStream = subscription.stream.map((event) {
      switch (event) {
        case QuerySuccess(:final value):
          return TypedQuerySuccess<double>(
            expectDouble(value, label: 'CountPublicResult'),
          );
        case QueryLoading(:final hasPendingWrites):
          return TypedQueryLoading<double>(hasPendingWrites: hasPendingWrites);
        case QueryError(:final message, :final data, :final logLines):
          return TypedQueryError<double>(
            message,
            data: data,
            logLines: logLines,
          );
      }
    });
    return TypedConvexSubscription<double>(subscription, typedStream);
  }

  Future<Null> failingSend({
    required String author,
    required String text,
  }) async {
    final raw = await _client.mutate(
      'messages:failingSend',
      _encodeFailingSendArgs((author: author, text: text)),
    );
    return null;
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
    final typedStream = subscription.stream.map((event) {
      switch (event) {
        case QuerySuccess(:final value):
          return TypedQuerySuccess<List<ListPrivateResultItem>>(
            expectList(
              value,
              label: 'ListPrivateResult',
            ).map((item) => _decodeListPrivateResultItem(item)).toList(),
          );
        case QueryLoading(:final hasPendingWrites):
          return TypedQueryLoading<List<ListPrivateResultItem>>(
            hasPendingWrites: hasPendingWrites,
          );
        case QueryError(:final message, :final data, :final logLines):
          return TypedQueryError<List<ListPrivateResultItem>>(
            message,
            data: data,
            logLines: logLines,
          );
      }
    });
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
    final typedStream = subscription.stream.map((event) {
      switch (event) {
        case QuerySuccess(:final value):
          return TypedQuerySuccess<List<ListPublicResultItem>>(
            expectList(
              value,
              label: 'ListPublicResult',
            ).map((item) => _decodeListPublicResultItem(item)).toList(),
          );
        case QueryLoading(:final hasPendingWrites):
          return TypedQueryLoading<List<ListPublicResultItem>>(
            hasPendingWrites: hasPendingWrites,
          );
        case QueryError(:final message, :final data, :final logLines):
          return TypedQueryError<List<ListPublicResultItem>>(
            message,
            data: data,
            logLines: logLines,
          );
      }
    });
    return TypedConvexSubscription<List<ListPublicResultItem>>(
      subscription,
      typedStream,
    );
  }

  TypedConvexPaginatedQuery<PaginatePublicPageItem> paginatePublic({
    int pageSize = 20,
  }) {
    final query = _client.paginatedQuery(
      'messages:paginatePublic',
      const <String, dynamic>{},
      pageSize: pageSize,
    );
    return TypedConvexPaginatedQuery<PaginatePublicPageItem>(
      query,
      (dynamic raw) => _decodePaginatePublicPageItem(raw),
    );
  }

  Future<double> seedPublic() async {
    final raw = await _client.mutate(
      'messages:seedPublic',
      const <String, dynamic>{},
    );
    return expectDouble(raw, label: 'SeedPublicResult');
  }

  Future<PrivateMessagesId> sendPrivate({
    Optional<String> author = const Optional.absent(),
    required String text,
  }) async {
    final raw = await _client.mutate(
      'messages:sendPrivate',
      _encodeSendPrivateArgs((author: author, text: text)),
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

typedef FailingSendArgs = ({String author, String text});

Map<String, dynamic> _encodeFailingSendArgs(FailingSendArgs value) {
  final (author: author, text: text) = value;
  return <String, dynamic>{'author': author, 'text': text};
}

FailingSendArgs _decodeFailingSendArgs(dynamic raw) {
  final map = expectMap(raw, label: 'FailingSendArgs');
  if (!map.containsKey('author')) {
    throw FormatException(
      'Missing required field "author" for FailingSendArgs',
    );
  }
  if (!map.containsKey('text')) {
    throw FormatException('Missing required field "text" for FailingSendArgs');
  }
  return (
    author: expectString(map['author'], label: 'FailingSendArgsAuthor'),
    text: expectString(map['text'], label: 'FailingSendArgsText'),
  );
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
  if (!map.containsKey('_creationTime')) {
    throw FormatException(
      'Missing required field "_creationTime" for ListPrivateResultItem',
    );
  }
  if (!map.containsKey('_id')) {
    throw FormatException(
      'Missing required field "_id" for ListPrivateResultItem',
    );
  }
  if (!map.containsKey('author')) {
    throw FormatException(
      'Missing required field "author" for ListPrivateResultItem',
    );
  }
  if (!map.containsKey('text')) {
    throw FormatException(
      'Missing required field "text" for ListPrivateResultItem',
    );
  }
  if (!map.containsKey('tokenIdentifier')) {
    throw FormatException(
      'Missing required field "tokenIdentifier" for ListPrivateResultItem',
    );
  }
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
  if (!map.containsKey('_creationTime')) {
    throw FormatException(
      'Missing required field "_creationTime" for ListPublicResultItem',
    );
  }
  if (!map.containsKey('_id')) {
    throw FormatException(
      'Missing required field "_id" for ListPublicResultItem',
    );
  }
  if (!map.containsKey('author')) {
    throw FormatException(
      'Missing required field "author" for ListPublicResultItem',
    );
  }
  if (!map.containsKey('text')) {
    throw FormatException(
      'Missing required field "text" for ListPublicResultItem',
    );
  }
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

typedef PaginatePublicPageItem = ({
  double creationTime,
  PublicMessagesId id,
  String author,
  String text,
});

Map<String, dynamic> _encodePaginatePublicPageItem(
  PaginatePublicPageItem value,
) {
  final (creationTime: creationTime, id: id, author: author, text: text) =
      value;
  return <String, dynamic>{
    '_creationTime': creationTime,
    '_id': id.value,
    'author': author,
    'text': text,
  };
}

PaginatePublicPageItem _decodePaginatePublicPageItem(dynamic raw) {
  final map = expectMap(raw, label: 'PaginatePublicPageItem');
  if (!map.containsKey('_creationTime')) {
    throw FormatException(
      'Missing required field "_creationTime" for PaginatePublicPageItem',
    );
  }
  if (!map.containsKey('_id')) {
    throw FormatException(
      'Missing required field "_id" for PaginatePublicPageItem',
    );
  }
  if (!map.containsKey('author')) {
    throw FormatException(
      'Missing required field "author" for PaginatePublicPageItem',
    );
  }
  if (!map.containsKey('text')) {
    throw FormatException(
      'Missing required field "text" for PaginatePublicPageItem',
    );
  }
  return (
    creationTime: expectDouble(
      map['_creationTime'],
      label: 'PaginatePublicPageItemCreationTime',
    ),
    id: PublicMessagesId(
      expectString(map['_id'], label: 'PaginatePublicPageItemId'),
    ),
    author: expectString(map['author'], label: 'PaginatePublicPageItemAuthor'),
    text: expectString(map['text'], label: 'PaginatePublicPageItemText'),
  );
}

typedef SendPrivateArgs = ({Optional<String> author, String text});

Map<String, dynamic> _encodeSendPrivateArgs(SendPrivateArgs value) {
  final (author: author, text: text) = value;
  return <String, dynamic>{
    if (author.isDefined) 'author': author.value,
    'text': text,
  };
}

SendPrivateArgs _decodeSendPrivateArgs(dynamic raw) {
  final map = expectMap(raw, label: 'SendPrivateArgs');
  if (!map.containsKey('text')) {
    throw FormatException('Missing required field "text" for SendPrivateArgs');
  }
  return (
    author: map.containsKey('author')
        ? Optional.of(
            expectString(map['author'], label: 'SendPrivateArgsAuthor'),
          )
        : const Optional.absent(),
    text: expectString(map['text'], label: 'SendPrivateArgsText'),
  );
}

typedef SendPublicArgs = ({String author, String text});

Map<String, dynamic> _encodeSendPublicArgs(SendPublicArgs value) {
  final (author: author, text: text) = value;
  return <String, dynamic>{'author': author, 'text': text};
}

SendPublicArgs _decodeSendPublicArgs(dynamic raw) {
  final map = expectMap(raw, label: 'SendPublicArgs');
  if (!map.containsKey('author')) {
    throw FormatException('Missing required field "author" for SendPublicArgs');
  }
  if (!map.containsKey('text')) {
    throw FormatException('Missing required field "text" for SendPublicArgs');
  }
  return (
    author: expectString(map['author'], label: 'SendPublicArgsAuthor'),
    text: expectString(map['text'], label: 'SendPublicArgsText'),
  );
}
