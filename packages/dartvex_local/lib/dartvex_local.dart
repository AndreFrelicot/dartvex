/// Offline-first extensions for Dartvex with local caching and mutation replay.
library;

export 'src/cache/cache_storage.dart'
    show CacheStorage, StoredCacheEntry, CachedQueryEntry;
export 'src/cache/query_cache.dart' show QueryCache;
export 'src/client.dart'
    show
        ConvexLocalClient,
        LocalClientConfig,
        LocalConnectionState,
        LocalMutationConflict,
        LocalMutationContext,
        LocalMutationFailed,
        LocalMutationHandler,
        LocalMutationPatch,
        LocalMutationQueued,
        LocalMutationResult,
        LocalMutationSuccess,
        LocalNetworkMode,
        LocalQueryDescriptor,
        LocalQueryError,
        LocalQueryEvent,
        LocalQuerySource,
        LocalQuerySuccess,
        LocalRemoteClient,
        LocalRemoteConnectionState,
        LocalRemoteQueryError,
        LocalRemoteQueryEvent,
        LocalRemoteQuerySuccess,
        LocalRemoteSubscription,
        LocalSubscription,
        PendingMutation,
        PendingMutationStatus;
export 'src/offline/mutation_queue.dart' show MutationQueue;
export 'src/offline/queue_storage.dart'
    show QueueStorage, StoredPendingMutation;
export 'src/runtime/convex_remote_client.dart' show ConvexRemoteClientAdapter;
export 'src/storage/sqlite_local_store.dart' show SqliteLocalStore;
export 'src/value_codec.dart' show JsonValueCodec, ValueCodec;
