/// Platform selector for the stored-image rendering helpers.
///
/// On native targets (`dart:io` available) this resolves to the real
/// `dartvex_flutter` disk-cache / offline image widgets; on web it falls back to
/// a no-`dart:io` stub so `flutter build web` stays green. Both modules expose
/// the same surface: [filesDiskCacheSupported], [buildCachedStorageImage],
/// [buildDownloadStorageImage], [buildOfflineStorageImage],
/// [readAssetCacheSizeBytes], and [clearAssetCache].
library;

export 'files_image_support_stub.dart'
    if (dart.library.io) 'files_image_support_io.dart';
