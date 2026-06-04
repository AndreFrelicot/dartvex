import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/material.dart';

import 'files_image_chrome.dart';

/// Native (mobile / desktop) image-support module.
///
/// Selected via the conditional export in `files_image_support.dart` whenever
/// `dart:io` is available. Renders stored images with the real `dartvex_flutter`
/// widgets — [ConvexImage] (stream + progress), [ConvexCachedImage] (disk
/// cache), [ConvexOfflineImage] (offline fallback) — and exposes the shared
/// [ConvexAssetCache] metrics. The web counterpart is `files_image_support_stub.dart`.

/// Whether the disk-cache / offline image stack runs on this platform.
const bool filesDiskCacheSupported = true;

/// Disk-cached image keyed by [storageId]; survives restarts and offline.
Widget buildCachedStorageImage({
  required String storageId,
  required String getUrlAction,
  required double size,
}) {
  return FilesImageFrame(
    size: size,
    child: ConvexCachedImage(
      storageId: storageId,
      getUrlAction: getUrlAction,
      width: size,
      height: size,
      fit: BoxFit.cover,
      placeholder: const FilesImageLoading(),
      errorWidget: const FilesImageError(),
    ),
  );
}

/// In-memory streaming download with a live progress ring (no disk cache).
Widget buildDownloadStorageImage({
  required String storageId,
  required String getUrlAction,
  required double size,
}) {
  return FilesImageFrame(
    size: size,
    child: ConvexImage(
      storageId: storageId,
      getUrlAction: getUrlAction,
      width: size,
      height: size,
      fit: BoxFit.cover,
      placeholder: const FilesImageLoading(),
      errorWidget: const FilesImageError(),
      progressBuilder: (context, progress) =>
          FilesImageProgress(progress.progress),
    ),
  );
}

/// Offline fallback: with `url: null` the widget consults the disk cache only,
/// so it shows the cached copy if present and "Not cached yet" otherwise.
Widget buildOfflineStorageImage({
  required String storageId,
  required double size,
}) {
  return FilesImageFrame(
    size: size,
    child: ConvexOfflineImage(
      cacheKey: storageId,
      url: null,
      cache: ConvexAssetCache.shared,
      builder: (context, snapshot) {
        if (snapshot.isLoading) {
          return const FilesImageLoading();
        }
        if (snapshot.hasError || !snapshot.hasFile) {
          return const FilesImageError(label: 'Not cached yet');
        }
        return Image.file(
          snapshot.file!,
          width: size,
          height: size,
          fit: BoxFit.cover,
        );
      },
    ),
  );
}

/// Total bytes held by the shared disk asset cache.
Future<int> readAssetCacheSizeBytes() {
  return ConvexAssetCache.shared.getSizeBytes();
}

/// Empties the shared disk asset cache.
Future<void> clearAssetCache() {
  return ConvexAssetCache.shared.clear();
}
