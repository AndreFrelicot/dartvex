---
name: dartvex-upload-files
description: Upload files to Convex storage and display stored images from Dart/Flutter with dartvex - signed upload URLs via ConvexStorage, and ConvexImage/ConvexCachedImage widgets with disk caching. Use when handling file or image upload/download, avatars, attachments, or Convex file storage from a dartvex app.
license: MIT
metadata:
  author: AndreFrelicot
  ecosystem-version: "0.2.0"
---

# Files and Images with Convex Storage

Convex file storage is a two-step protocol: a backend mutation issues a
signed upload URL, the client POSTs bytes to it and receives a `storageId`;
a backend query/action resolves a `storageId` back to a signed download URL.

## Backend prerequisite

Two tiny functions (anything richer → official Convex skills,
`npx skills add get-convex/agent-skills`):

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
  uploadUrlAction: 'files:generateUploadUrl', // a mutation
  bytes: imageBytes,                          // Uint8List
  filename: 'photo.jpg',
  contentType: 'image/jpeg',
);
// Persist storageId in your data model via a normal mutation.
```

Failures throw `ConvexFileUploadException` (HTTP status + body) or
`ConvexStorageException` (bad resolver response).

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
`ConvexOfflineImage` / `ConvexAssetCache` add offline-fallback binary
caching.

### Flutter web caveat

`ConvexImage`, `ConvexCachedImage`, `ConvexOfflineImage`, and
`ConvexAssetCache` are **native-only** (they use `dart:io` and
`flutter_cache_manager`). On web, resolve the URL with
`storage.getFileUrl(...)` and render with `Image.network(url)`.

## Common mistakes

- Passing a query name as `uploadUrlAction` — the upload-URL resolver is a
  **mutation** (the parameter name notwithstanding).
- Storing the signed URL instead of the `storageId` — signed URLs expire;
  persist the ID and re-resolve.
- Using the cached-image widgets on web — gate by platform and fall back to
  `Image.network`.
- Uploading huge files in one `Uint8List` on memory-constrained devices —
  consider size limits in the UI; the POST is a single body.
