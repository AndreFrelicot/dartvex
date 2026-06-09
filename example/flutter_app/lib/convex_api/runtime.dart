// GENERATED CODE - DO NOT MODIFY BY HAND.

import 'dart:async';
import 'dart:typed_data';

import 'package:dartvex/dartvex.dart';

abstract class ConvexTableId {
  const ConvexTableId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is ConvexTableId &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => value;
}

sealed class Optional<T> {
  const Optional();

  const factory Optional.absent() = _OptionalAbsent<T>;
  const factory Optional.of(T value) = _OptionalValue<T>;

  bool get isDefined;
  T get value;
  T? get valueOrNull;
}

class _OptionalAbsent<T> extends Optional<T> {
  const _OptionalAbsent();

  @override
  bool get isDefined => false;

  @override
  T get value => throw StateError('Optional value is absent');

  @override
  T? get valueOrNull => null;

  @override
  bool operator ==(Object other) => other is _OptionalAbsent<T>;

  @override
  int get hashCode => T.hashCode;
}

class _OptionalValue<T> extends Optional<T> {
  const _OptionalValue(this.value);

  @override
  final T value;

  @override
  bool get isDefined => true;

  @override
  T get valueOrNull => value;

  @override
  bool operator ==(Object other) =>
      other is _OptionalValue<T> && other.value == value;

  @override
  int get hashCode => Object.hash(T, value);
}

sealed class TypedQueryResult<T> {
  const TypedQueryResult();
}

class TypedQuerySuccess<T> extends TypedQueryResult<T> {
  const TypedQuerySuccess(this.value);

  final T value;
}

class TypedQueryLoading<T> extends TypedQueryResult<T> {
  const TypedQueryLoading({this.hasPendingWrites = false});

  final bool hasPendingWrites;
}

class TypedQueryError<T> extends TypedQueryResult<T> {
  const TypedQueryError(
    this.message, {
    this.data,
    this.logLines = const <String>[],
  });

  final String message;
  final Object? data;
  final List<String> logLines;
}

class TypedConvexSubscription<T> {
  const TypedConvexSubscription(this._delegate, this.stream);

  final ConvexSubscription _delegate;
  final Stream<TypedQueryResult<T>> stream;

  void cancel() {
    _delegate.cancel();
  }
}

class TypedConvexPaginatedResult<T> {
  const TypedConvexPaginatedResult({
    required this.items,
    required this.status,
    required this.isDone,
    this.error,
  });

  final List<T> items;
  final ConvexPaginationStatus status;
  final bool isDone;
  final Object? error;
}

class TypedConvexPaginatedQuery<T> {
  TypedConvexPaginatedQuery(this._delegate, this._decode);

  final ConvexPaginatedQuery _delegate;
  final T Function(dynamic raw) _decode;

  Stream<TypedConvexPaginatedResult<T>> get stream =>
      _delegate.stream.map(_toTyped);

  TypedConvexPaginatedResult<T> get current => _toTyped(_delegate.current);

  List<T> get items => _delegate.current.results.map(_decode).toList();

  ConvexPaginationStatus get status => _delegate.status;

  bool get isDone => _delegate.isDone;

  bool loadMore([int? numItems]) => _delegate.loadMore(numItems);

  void cancel() {
    _delegate.cancel();
  }

  TypedConvexPaginatedResult<T> _toTyped(ConvexPaginatedResult result) {
    return TypedConvexPaginatedResult<T>(
      items: result.results.map(_decode).toList(),
      status: result.status,
      isDone: result.isDone,
      error: result.error,
    );
  }
}

Map<String, dynamic> expectMap(dynamic value, {String? label}) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.cast<String, dynamic>();
  }
  throw FormatException(
    'Expected ${label ?? 'object'}, got ${describeType(value)}',
  );
}

List<dynamic> expectList(dynamic value, {String? label}) {
  if (value is List<dynamic>) {
    return value;
  }
  if (value is List) {
    return value.cast<dynamic>();
  }
  throw FormatException(
    'Expected ${label ?? 'list'}, got ${describeType(value)}',
  );
}

String expectString(dynamic value, {String? label}) {
  if (value is String) {
    return value;
  }
  throw FormatException(
    'Expected ${label ?? 'string'}, got ${describeType(value)}',
  );
}

bool expectBool(dynamic value, {String? label}) {
  if (value is bool) {
    return value;
  }
  throw FormatException(
    'Expected ${label ?? 'bool'}, got ${describeType(value)}',
  );
}

double expectDouble(dynamic value, {String? label}) {
  if (value is num) {
    return value.toDouble();
  }
  throw FormatException(
    'Expected ${label ?? 'number'}, got ${describeType(value)}',
  );
}

BigInt expectBigInt(dynamic value, {String? label}) {
  if (value is BigInt) {
    return value;
  }
  throw FormatException(
    'Expected ${label ?? 'bigint'}, got ${describeType(value)}',
  );
}

Uint8List expectBytes(dynamic value, {String? label}) {
  if (value is Uint8List) {
    return value;
  }
  throw FormatException(
    'Expected ${label ?? 'bytes'}, got ${describeType(value)}',
  );
}

T expectLiteral<T>(dynamic value, T expected, {String? label}) {
  if (value == expected) {
    return expected;
  }
  throw FormatException(
    'Expected ${label ?? 'literal'} value $expected, got ${describeType(value)}',
  );
}

String describeType(dynamic value) {
  if (value == null) {
    return 'null';
  }
  return value.runtimeType.toString();
}
