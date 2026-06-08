import 'package:dartvex/dartvex.dart' show ConvexStorageException;

/// Returns a non-empty storage URL or throws a typed storage exception.
String requireStorageUrl(Object? value, String storageId) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  throw ConvexStorageException('No URL returned for storageId $storageId');
}
