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
        ConvexClient,
        ConvexFunctionCaller,
        ConvexSubscription,
        QueryError,
        QueryResult,
        QuerySuccess;
export 'src/config.dart' show ConvexClientConfig;
export 'src/exceptions.dart' show ConvexException, ConvexFileUploadException;
export 'src/logging.dart' show DartvexLogEvent, DartvexLogger, DartvexLogLevel;
export 'src/storage.dart' show ConvexStorage;
export 'src/transport/ws_manager.dart'
    show TransitionMetrics, TransitionMetricsCallback;
