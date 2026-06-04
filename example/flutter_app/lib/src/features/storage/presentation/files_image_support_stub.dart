import 'package:flutter/material.dart';

import 'files_image_chrome.dart';

/// Web image-support module (default export; no `dart:io`).
///
/// The `dartvex_flutter` image stack — [ConvexCachedImage], [ConvexImage],
/// [ConvexOfflineImage], [ConvexAssetCache] — is built on `dart:io`
/// (`File` / `HttpClient` / `flutter_cache_manager`), so it cannot compile for
/// the web target. The conditional export in `files_image_support.dart` picks
/// this stub when `dart:io` is absent, keeping `flutter build web` green while
/// the native module (`files_image_support_io.dart`) ships the real widgets.
///
/// Upload (`ConvexStorage`, HTTP-based) and the live `files:list` subscription
/// still work on web; only the bitmap rendering degrades to a placeholder.

/// Disk caching / offline images are unavailable on this platform.
const bool filesDiskCacheSupported = false;

Widget buildCachedStorageImage({
  required String storageId,
  required String getUrlAction,
  required double size,
}) {
  return FilesImageFrame(size: size, child: const FilesImageUnsupported());
}

Widget buildDownloadStorageImage({
  required String storageId,
  required String getUrlAction,
  required double size,
}) {
  return FilesImageFrame(size: size, child: const FilesImageUnsupported());
}

Widget buildOfflineStorageImage({
  required String storageId,
  required double size,
}) {
  return FilesImageFrame(size: size, child: const FilesImageUnsupported());
}

Future<int> readAssetCacheSizeBytes() async => 0;

Future<void> clearAssetCache() async {}
