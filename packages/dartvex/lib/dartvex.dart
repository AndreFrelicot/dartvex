/// Pure Dart client APIs for communicating with a Convex deployment.
library;

export 'src/auth/auth_client.dart' show ConvexAuthClient;
export 'src/auth/auth_manager.dart' show AuthHandle;
export 'src/auth/auth_provider.dart' show AuthProvider;
export 'src/auth/auth_state.dart'
    show AuthAuthenticated, AuthLoading, AuthState, AuthUnauthenticated;
export 'src/auth/client_with_auth.dart' show ConvexClientWithAuth;
export 'src/client.dart'
    show
        ConnectionState,
        ConnectionStatus,
        ConvexClient,
        ConvexFunctionCaller,
        ConvexSubscription,
        QueryError,
        QueryLoading,
        QueryResult,
        QuerySuccess;
export 'src/config.dart' show ConvexClientConfig, WebSocketAdapterFactory;
export 'src/exceptions.dart'
    show ConvexException, ConvexFileUploadException, ConvexStorageException;
export 'src/logging.dart' show DartvexLogEvent, DartvexLogger, DartvexLogLevel;
export 'src/storage.dart' show ConvexStorage;
export 'src/sync/optimistic_updates.dart'
    show OptimisticLocalStore, OptimisticQueryEntry, OptimisticUpdate;
export 'src/sync/paginated_query.dart'
    show
        ConvexPaginatedQuery,
        ConvexPaginatedResult,
        ConvexPaginationStatus,
        PageInitialResultReader,
        PageSubscriber,
        PageSubscription;
export 'src/transport/connectivity.dart' show ConnectivitySignal;
export 'src/transport/http_factory.dart'
    show createDefaultHttpClient, defaultHttpClientFactory;
export 'src/transport/ws_factory.dart'
    show createDefaultWebSocketAdapter, defaultWebSocketAdapterOverride;
export 'src/transport/ws_interface.dart'
    show WebSocketAdapter, WebSocketCloseEvent;
export 'src/transport/ws_manager.dart'
    show TransitionMetrics, TransitionMetricsCallback;
export 'src/values/json_codec.dart'
    show convexInt64, convexToJson, jsonToConvex;
