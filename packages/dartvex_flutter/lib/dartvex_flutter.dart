/// Flutter widgets and runtime adapters for building reactive Convex UIs.
library;

// Re-exported from the core package so optimistic updates and paginated query
// results can be used with a single `dartvex_flutter` import.
export 'package:dartvex/dartvex.dart'
    show
        ConnectionStatus,
        ConvexPaginatedResult,
        ConvexPaginationStatus,
        OptimisticLocalStore,
        OptimisticQueryEntry,
        OptimisticUpdate;

export 'src/action_builder.dart' show ConvexAction, ConvexActionBuilder;
export 'src/asset_cache.dart' show ConvexAssetCache, ConvexAssetCacheMetrics;
export 'src/convex_cached_image.dart' show ConvexCachedImage;
export 'src/convex_image.dart' show ConvexImage;
export 'src/file_downloader.dart'
    show
        ConvexFileDownloader,
        ConvexDownloadProgress,
        ConvexDownloadProgressCallback;
export 'src/offline_image.dart' show ConvexAssetSnapshot, ConvexOfflineImage;
export 'src/auth_builder.dart' show ConvexAuthBuilder, ConvexAuthWidgetBuilder;
export 'src/auth_provider.dart' show ConvexAuthProvider;
export 'src/auth_refreshing_builder.dart'
    show ConvexAuthRefreshingBuilder, ConvexAuthRefreshingWidgetBuilder;
export 'src/connection_builder.dart'
    show
        ConvexConnectionBuilder,
        ConvexConnectionStatusBuilder,
        ConvexConnectionStatusWidgetBuilder,
        ConvexConnectionWidgetBuilder;
export 'src/connection_indicator.dart'
    show ConvexConnectionIndicator, ConvexConnectionIndicatorBuilder;
export 'src/connectivity.dart' show ConnectivityPlusSignal;
export 'src/mutation_builder.dart' show ConvexMutation, ConvexMutationBuilder;
export 'src/paginated_query_builder.dart'
    show PaginatedQueryBuilder, PaginatedQueryWidgetBuilder, PaginationStatus;
export 'src/provider.dart' show ConvexProvider;
export 'src/query_builder.dart' show ConvexQuery, ConvexQueryWidgetBuilder;
export 'src/runtime_client.dart'
    show
        ConvexClientRuntime,
        ConvexConnectionState,
        ConvexRuntimeClient,
        ConvexRuntimePaginatedQuery,
        ConvexRuntimeQueryError,
        ConvexRuntimeQueryEvent,
        ConvexRuntimeQuerySuccess,
        ConvexRuntimeSubscription;
export 'src/snapshot.dart'
    show
        ConvexDecoder,
        ConvexQuerySnapshot,
        ConvexQuerySource,
        ConvexRequestExecutor,
        ConvexRequestSnapshot;
export 'src/testing/fake_convex_client.dart'
    show FakeConvexClient, FakeConvexPaginatedQuery, FakeConvexSubscription;
