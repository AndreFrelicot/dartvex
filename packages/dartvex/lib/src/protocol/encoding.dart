import 'dart:convert';
import 'dart:typed_data';

final BigInt _maxUint64 = (BigInt.one << 64) - BigInt.one;
final BigInt _byteMask = BigInt.from(0xff);

String encodeTs(int ts) {
  return encodeTsBigInt(BigInt.from(ts));
}

String encodeTsBigInt(BigInt ts) {
  if (ts < BigInt.zero || ts > _maxUint64) {
    throw ArgumentError.value(
      ts,
      'ts',
      'Convex timestamps must fit in an unsigned 64-bit integer.',
    );
  }
  final bytes = Uint8List(8);
  var value = ts;
  for (var index = 0; index < bytes.length; index += 1) {
    bytes[index] = (value & _byteMask).toInt();
    value = value >> 8;
  }
  return base64Encode(bytes);
}

BigInt decodeTs(String encoded) {
  final bytes = base64Decode(encoded);
  if (bytes.length != 8) {
    throw FormatException(
      'Convex timestamps must be 8 bytes, got ${bytes.length}',
      encoded,
    );
  }
  var value = BigInt.zero;
  for (var index = bytes.length - 1; index >= 0; index -= 1) {
    value = (value << 8) + BigInt.from(bytes[index]);
  }
  return value;
}

int compareEncodedTs(String left, String right) {
  final leftBytes = base64Decode(left);
  final rightBytes = base64Decode(right);
  if (leftBytes.length != 8 || rightBytes.length != 8) {
    throw FormatException(
      'Convex timestamps must be 8 bytes',
      <String, Object?>{
        'leftLength': leftBytes.length,
        'rightLength': rightBytes.length,
      },
    );
  }
  for (var index = leftBytes.length - 1; index >= 0; index -= 1) {
    final difference = leftBytes[index] - rightBytes[index];
    if (difference != 0) {
      return difference;
    }
  }
  return 0;
}
