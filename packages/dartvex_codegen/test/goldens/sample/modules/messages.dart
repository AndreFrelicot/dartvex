// GENERATED CODE - DO NOT MODIFY BY HAND.

import '../runtime.dart';
import '../schema.dart';
import 'dart:typed_data';
import 'package:dartvex/dartvex.dart';

class MessagesApi {
  const MessagesApi(this._client);

  final ConvexFunctionCaller _client;

  Future<List<ListResultItem>> list({
    Optional<double> limit = const Optional.absent(),
    Optional<String?> author = const Optional.absent(),
    Optional<ListArgsFilters> filters = const Optional.absent(),
  }) async {
    final raw = await _client.query(
      'messages:list',
      _encodeListArgs((limit: limit, author: author, filters: filters)),
    );
    return expectList(
      raw,
      label: 'ListResult',
    ).map((item) => _decodeListResultItem(item)).toList();
  }

  TypedConvexSubscription<List<ListResultItem>> listSubscribe({
    Optional<double> limit = const Optional.absent(),
    Optional<String?> author = const Optional.absent(),
    Optional<ListArgsFilters> filters = const Optional.absent(),
  }) {
    final subscription = _client.subscribe(
      'messages:list',
      _encodeListArgs((limit: limit, author: author, filters: filters)),
    );
    final typedStream = subscription.stream.map(
      (event) => switch (event) {
        QuerySuccess(:final value) => TypedQuerySuccess<List<ListResultItem>>(
          expectList(
            value,
            label: 'ListResult',
          ).map((item) => _decodeListResultItem(item)).toList(),
        ),
        QueryError(:final message) => TypedQueryError<List<ListResultItem>>(
          message,
        ),
      },
    );
    return TypedConvexSubscription<List<ListResultItem>>(
      subscription,
      typedStream,
    );
  }

  Future<MessagesId> send({
    required String author,
    required String text,
    Optional<Uint8List> attachment = const Optional.absent(),
  }) async {
    final raw = await _client.mutate(
      'messages:send',
      _encodeSendArgs((author: author, text: text, attachment: attachment)),
    );
    return MessagesId(expectString(raw, label: 'SendResult'));
  }
}

enum ListResultItemStatus {
  draftValue('draft'),
  sentValue('sent');

  const ListResultItemStatus(this.value);
  final Object? value;

  static ListResultItemStatus fromJson(dynamic raw) {
    switch (raw) {
      case 'draft':
        return ListResultItemStatus.draftValue;
      case 'sent':
        return ListResultItemStatus.sentValue;
      default:
        throw FormatException(
          'Expected one of draft, sent for ListResultItemStatus',
        );
    }
  }
}

typedef ListResultItem = ({
  MessagesId id,
  String author,
  String text,
  ListResultItemStatus status,
});

Map<String, dynamic> _encodeListResultItem(ListResultItem value) {
  final (id: id, author: author, text: text, status: status) = value;
  return <String, dynamic>{
    '_id': id.value,
    'author': author,
    'text': text,
    'status': status.value,
  };
}

ListResultItem _decodeListResultItem(dynamic raw) {
  final map = expectMap(raw, label: 'ListResultItem');
  return (
    id: MessagesId(expectString(map['_id'], label: 'ListResultItemId')),
    author: expectString(map['author'], label: 'ListResultItemAuthor'),
    text: expectString(map['text'], label: 'ListResultItemText'),
    status: ListResultItemStatus.fromJson(map['status']),
  );
}

typedef ListArgsFilters = ({Optional<String> tag});

Map<String, dynamic> _encodeListArgsFilters(ListArgsFilters value) {
  final (tag: tag) = value;
  return <String, dynamic>{if (tag.isDefined) 'tag': tag.value};
}

ListArgsFilters _decodeListArgsFilters(dynamic raw) {
  final map = expectMap(raw, label: 'ListArgsFilters');
  return (
    tag: map.containsKey('tag')
        ? Optional.of(expectString(map['tag'], label: 'ListArgsFiltersTag'))
        : const Optional.absent(),
  );
}

typedef ListArgs = ({
  Optional<double> limit,
  Optional<String?> author,
  Optional<ListArgsFilters> filters,
});

Map<String, dynamic> _encodeListArgs(ListArgs value) {
  final (limit: limit, author: author, filters: filters) = value;
  return <String, dynamic>{
    if (limit.isDefined) 'limit': limit.value,
    if (author.isDefined) 'author': author.value == null ? null : author.value,
    if (filters.isDefined) 'filters': _encodeListArgsFilters(filters.value),
  };
}

ListArgs _decodeListArgs(dynamic raw) {
  final map = expectMap(raw, label: 'ListArgs');
  return (
    limit: map.containsKey('limit')
        ? Optional.of(expectDouble(map['limit'], label: 'ListArgsLimit'))
        : const Optional.absent(),
    author: map.containsKey('author')
        ? Optional.of(
            map['author'] == null
                ? null
                : expectString(map['author'], label: 'ListArgsAuthor'),
          )
        : const Optional.absent(),
    filters: map.containsKey('filters')
        ? Optional.of(_decodeListArgsFilters(map['filters']))
        : const Optional.absent(),
  );
}

typedef SendArgs = ({
  String author,
  String text,
  Optional<Uint8List> attachment,
});

Map<String, dynamic> _encodeSendArgs(SendArgs value) {
  final (author: author, text: text, attachment: attachment) = value;
  return <String, dynamic>{
    'author': author,
    'text': text,
    if (attachment.isDefined) 'attachment': attachment.value,
  };
}

SendArgs _decodeSendArgs(dynamic raw) {
  final map = expectMap(raw, label: 'SendArgs');
  return (
    author: expectString(map['author'], label: 'SendArgsAuthor'),
    text: expectString(map['text'], label: 'SendArgsText'),
    attachment: map.containsKey('attachment')
        ? Optional.of(
            expectBytes(map['attachment'], label: 'SendArgsAttachment'),
          )
        : const Optional.absent(),
  );
}
