import 'dart:convert';
import 'dart:typed_data';

String encodeTs(int ts) {
  final bytes = Uint8List(8);
  final data = ByteData.sublistView(bytes);
  data.setUint64(0, ts, Endian.little);
  return base64Encode(bytes);
}

int decodeTs(String encoded) {
  final bytes = base64Decode(encoded);
  if (bytes.length != 8) {
    throw FormatException(
      'Convex timestamps must be 8 bytes, got ${bytes.length}',
      encoded,
    );
  }
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  return data.getUint64(0, Endian.little);
}
