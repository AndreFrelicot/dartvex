import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/material.dart';

import 'files_image_chrome.dart';

/// Web image-support module (default export; no `dart:io`).
///
/// The `dartvex_flutter` image stack — [ConvexCachedImage], [ConvexImage],
/// [ConvexOfflineImage], [ConvexAssetCache] — is built on `dart:io`
/// (`File` / `HttpClient` / `flutter_cache_manager`), so it cannot compile for
/// the web target. The conditional export in `files_image_support.dart` picks
/// this stub when `dart:io` is absent, keeping `flutter build web` green. The
/// web gallery renders signed storage URLs with `Image.network` directly from
/// `files_panel.dart`; this module only guards native-only cache/offline helpers
/// against accidental use on web.
///
/// Upload (`ConvexStorage`, HTTP-based) and the live `files:list` subscription
/// still work on web; only disk-cache / offline fallback helpers are omitted.

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

/// Full-resolution image for the fullscreen viewer.
///
/// On web there is no disk cache and no `dart:io` blackhole, so the browser's
/// own `Image.network` (resolving the signed URL via a reactive query) is the
/// right path.
Widget buildFullscreenStorageImage({
  required String storageId,
  required String getUrlAction,
  required double width,
  required double height,
}) {
  return ConvexQuery<String?>(
    query: getUrlAction,
    args: <String, dynamic>{'storageId': storageId},
    decode: (value) => value as String?,
    builder: (context, snapshot) {
      final url = snapshot.data;
      if (snapshot.isLoading && url == null) {
        return const Center(child: FilesImageLoading());
      }
      if (snapshot.hasError || url == null || url.isEmpty) {
        return const Center(child: FilesImageError());
      }
      return Image.network(
        url,
        width: width,
        height: height,
        fit: BoxFit.contain,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) {
            return child;
          }
          final expected = loadingProgress.expectedTotalBytes;
          final progress = expected == null || expected == 0
              ? -1.0
              : loadingProgress.cumulativeBytesLoaded / expected;
          return Center(child: FilesImageProgress(progress));
        },
        errorBuilder: (context, error, stackTrace) =>
            const Center(child: FilesImageError()),
      );
    },
  );
}

Future<int> readAssetCacheSizeBytes() async => 0;

Future<void> clearAssetCache() async {}
