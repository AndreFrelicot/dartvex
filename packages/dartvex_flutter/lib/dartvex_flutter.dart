/// Flutter widgets and runtime adapters for building reactive Convex UIs.
library;

// Re-exported from the core package so auth states (for ConvexAuthBuilder),
// optimistic updates, paginated query results, and the transport override seams (the documented opt-out from the
// NSURLSession transports) can be used with a single `dartvex_flutter` import.
export 'package:dartvex/dartvex.dart'
    show
        AuthAuthenticated,
        AuthLoading,
        AuthSessionEndedError,
        AuthState,
        AuthUnauthenticated,
        ConnectionStatus,
        ConvexAuthClient,
        ConvexPaginatedResult,
        ConvexPaginationStatus,
        ConvexStorageException,
        OptimisticLocalStore,
        OptimisticQueryEntry,
        OptimisticUpdate,
        defaultHttpClientFactory,
        defaultWebSocketAdapterOverride;

export 'src/action_builder.dart' show ConvexAction, ConvexActionBuilder;
// NSURLSession transport: installed automatically on iOS/macOS via
// DartvexFlutterPlugin.registerWith(); installCupertinoTransport is exported
// for apps that need to re-install it after opting out.
export 'src/plugin.dart' show DartvexFlutterPlugin;
export 'src/transport/cupertino_web_socket_adapter_stub.dart'
    if (dart.library.io) 'src/transport/cupertino_web_socket_adapter.dart'
    show installCupertinoTransport;
export 'src/media_types.dart'
    show
        ConvexAssetCacheMetrics,
        ConvexDownloadProgress,
        ConvexDownloadProgressCallback,
        ConvexImageErrorBuilder;
// Native-only media helpers (dart:io, flutter_cache_manager). Web builds (JS
// and WASM) get API-compatible stand-ins, so the web import graph stays free
// of dart:io. The native file is the default so static analysis (and IDEs)
// always see the real types.
export 'src/native_only_io.dart'
    if (dart.library.js_interop) 'src/native_only_stub.dart'
    show
        ConvexAssetCache,
        ConvexAssetSnapshot,
        ConvexCachedImage,
        ConvexFileDownloader,
        ConvexImage,
        ConvexOfflineImage;
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
    show
        PaginatedQueryBuilder,
        PaginatedQueryErrorWidgetBuilder,
        PaginatedQueryWidgetBuilder,
        PaginationStatus;
export 'src/provider.dart' show ConvexProvider;
export 'src/query_builder.dart' show ConvexQuery, ConvexQueryWidgetBuilder;
export 'src/runtime_watch.dart' show ConvexRuntimeWatch;
export 'src/runtime_client.dart'
    show
        ConvexClientRuntime,
        ConvexConnectionState,
        ConvexFunctionCallerSource,
        ConvexRuntimeClient,
        ConvexRuntimeFunctionCaller,
        ConvexRuntimePaginatedQuery,
        ConvexRuntimeQueryError,
        ConvexRuntimeQueryEvent,
        ConvexRuntimeQueryLoading,
        ConvexRuntimeQuerySuccess,
        ConvexRuntimeSubscription;
export 'src/snapshot.dart'
    show
        ConvexDecodeException,
        ConvexDecoder,
        ConvexQuerySnapshot,
        ConvexQuerySource,
        ConvexRequestExecutor,
        ConvexRequestSnapshot;
export 'src/testing/fake_convex_auth_client.dart' show FakeConvexAuthClient;
export 'src/testing/fake_convex_client.dart'
    show
        FakeConvexCall,
        FakeConvexClient,
        FakeConvexPaginatedQuery,
        FakeConvexSubscription;
