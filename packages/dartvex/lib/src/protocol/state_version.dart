import 'encoding.dart';

class StateVersion {
  const StateVersion({
    required this.querySet,
    required this.identity,
    required this.ts,
  });

  const StateVersion.initial()
      : querySet = 0,
        identity = 0,
        ts = 'AAAAAAAAAAA=';

  final int querySet;
  final int identity;
  final String ts;

  int get decodedTs => decodeTs(ts);

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'querySet': querySet,
      'identity': identity,
      'ts': ts,
    };
  }

  factory StateVersion.fromJson(Map<String, dynamic> json) {
    return StateVersion(
      querySet: json['querySet'] as int,
      identity: json['identity'] as int,
      ts: json['ts'] as String,
    );
  }

  bool isSameVersion(StateVersion other) {
    return querySet == other.querySet &&
        identity == other.identity &&
        ts == other.ts;
  }

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
