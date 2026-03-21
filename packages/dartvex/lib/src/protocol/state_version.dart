import 'encoding.dart';

/// Version vector describing the current synchronized query state.
class StateVersion {
  /// Creates a state version.
  const StateVersion({
    required this.querySet,
    required this.identity,
    required this.ts,
  });

  /// Creates the initial zeroed state version.
  const StateVersion.initial()
      : querySet = 0,
        identity = 0,
        ts = 'AAAAAAAAAAA=';

  /// Query-set version component.
  final int querySet;

  /// Identity/auth version component.
  final int identity;

  /// Encoded timestamp component.
  final String ts;

  /// Decoded integer timestamp represented by [ts].
  int get decodedTs => decodeTs(ts);

  /// Serializes this version to JSON.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'querySet': querySet,
      'identity': identity,
      'ts': ts,
    };
  }

  /// Deserializes a [StateVersion] from JSON.
  factory StateVersion.fromJson(Map<String, dynamic> json) {
    return StateVersion(
      querySet: json['querySet'] as int,
      identity: json['identity'] as int,
      ts: json['ts'] as String,
    );
  }

  /// Returns whether this version matches [other] exactly.
  bool isSameVersion(StateVersion other) {
    return querySet == other.querySet &&
        identity == other.identity &&
        ts == other.ts;
  }

  /// Returns whether this version's timestamp is at least [otherTs].
  bool isTsAtLeast(String otherTs) {
    return decodedTs >= decodeTs(otherTs);
  }

  @override
  bool operator ==(Object other) {
    return other is StateVersion &&
        other.querySet == querySet &&
        other.identity == identity &&
        other.ts == ts;
  }

  @override
  int get hashCode => Object.hash(querySet, identity, ts);
}
