---
name: dartvex-upload-files
description: Upload files to Convex storage and display stored images from Dart/Flutter with dartvex - signed upload URLs via ConvexStorage, small files as bytes in a mutation, and ConvexImage/ConvexCachedImage widgets with disk caching. Use when handling file or image upload/download, avatars, attachments, or Convex file storage from a dartvex app.
license: MIT
metadata:
  author: AndreFrelicot
  ecosystem-version: "0.3.0"
---

# Files and Images with Convex Storage

Convex file storage is a two-step protocol: a backend mutation issues a
signed upload URL, the client POSTs bytes to it and receives a `storageId`;
a backend query/action resolves a `storageId` back to a signed download URL.

## Backend prerequisite

Two tiny functions (anything richer → official Convex skills,
`npx skills add convex/agent-skills`):

```typescript
// convex/files.ts
import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

export const generateUploadUrl = mutation({
  handler: (ctx) => ctx.storage.generateUploadUrl(),
});

export const getUrl = query({
  args: { storageId: v.id("_storage") },
  handler: (ctx, args) => ctx.storage.getUrl(args.storageId),
});
```

## Upload from Dart — ConvexStorage

```dart
import 'package:dartvex/dartvex.dart';

final storage = ConvexStorage(client);

final storageId = await storage.uploadFile(
  uploadUrlAction: 'files:generateUploadUrl', // a mutation by default
  bytes: imageBytes,                          // Uint8List
  contentType: 'image/jpeg',
  filename: 'photo.jpg',              // optional; only used in debug logs
  timeout: const Duration(minutes: 2), // optional; bounds the upload POST
  // useAction: true — when the upload URL comes from an action
);
// Persist storageId (and the filename, if you need it) via a normal mutation.
```

Failures throw `ConvexFileUploadException` (HTTP status + body),
`ConvexStorageException` (bad resolver response), or `TimeoutException`
when `timeout` expires. `ConvexStorage` takes any `ConvexFunctionCaller`;
in Flutter use `ConvexStorage(ConvexProvider.of(context).functionCaller)`.

## Small files: bytes in one mutation

Convex mutations can store files themselves (`ctx.storage.store`), so a
small file can travel as a `v.bytes()` argument (a Dart `Uint8List`) and be
stored and recorded in one transaction, without the upload-URL round trip.
No SDK helper is needed:

```typescript
// convex/files.ts
export const saveAvatar = mutation({
  args: { bytes: v.bytes(), contentType: v.string() },
  handler: async (ctx, { bytes, contentType }) => {
    const storageId = await ctx.storage.store(
      new Blob([bytes], { type: contentType }),
    );
    // ...record storageId in your tables, in the same transaction
    return storageId;
  },
});
```

```dart
final storageId = await client.mutate('files:saveAvatar', {
  'bytes': avatarBytes, // Uint8List
  'contentType': 'image/png',
});
```

Keep it to small files: the bytes count against Convex's function-argument
size limit and the mutation's file-write limits (see
https://docs.convex.dev/production/state/limits); use `uploadFile` for
anything larger. With `dartvex_local`, such a mutation can also be queued
offline (the bytes are persisted in the queue).

## Download URL

```dart
final url = await storage.getFileUrl(
  getUrlAction: 'files:getUrl',
  storageId: storageId,
  // useAction: true — when the resolver is an action instead of a query
);
```

## Display images (Flutter, native targets)

```dart
import 'package:dartvex_flutter/dartvex_flutter.dart';

// Resolve + render:
ConvexImage(storageId: id, getUrlAction: 'files:getUrl')

// Resolve + render + persistent disk cache (survives restarts):
ConvexCachedImage(
  storageId: message.imageStorageId,
  getUrlAction: 'files:getUrl',
  width: 160,
  height: 160,
  fit: BoxFit.cover,
)
```

Set `useAction: true` on either widget when the URL resolver is an action.
Pass `errorBuilder: (context, error, retry) => ...` to render failures with a
retry button; without `errorBuilder`/`errorWidget`, failures are reported to
`FlutterError.reportError` (visible in widget tests). `ConvexOfflineImage` /
`ConvexAssetCache` add offline-fallback binary caching; `ConvexAssetCache()`
instances with the same `cacheKey` share one store.

### Flutter web caveat

`ConvexImage`, `ConvexCachedImage`, `ConvexOfflineImage`, and
`ConvexAssetCache` are **native-only** (they use `dart:io` and
`flutter_cache_manager`). Web builds (JS and WASM) still compile — they get
stand-ins that render the error state or throw `UnsupportedError` — but to
show images on web, resolve the URL with `storage.getFileUrl(...)` and render
with `Image.network(url)`.

## Common mistakes

- Passing a query name as `uploadUrlAction` — the upload-URL resolver is a
  **mutation** (the parameter name notwithstanding).
- Storing the signed URL instead of the `storageId` — signed URLs expire;
  persist the ID and re-resolve.
- Using the cached-image widgets on web — gate by platform and fall back to
  `Image.network`.
- Uploading huge files in one `Uint8List` on memory-constrained devices —
  consider size limits in the UI; the POST is a single body.
- Sending large files as mutation arguments — only small files fit; use
  `uploadFile` beyond that.
