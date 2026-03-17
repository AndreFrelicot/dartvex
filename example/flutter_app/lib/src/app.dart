import 'dart:async';

import 'package:dartvex_auth_better/dartvex_auth_better.dart';
import 'package:dartvex/dartvex.dart';
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:dartvex_local/dartvex_local.dart';
import 'package:flutter/material.dart';

import '../convex_api/api.dart';
import 'core/bundled_demo_token.dart';
import 'core/demo_reconnect_controller.dart';
import 'core/local_runtime_client.dart';
import 'core/unavailable_runtime_client.dart';
import 'features/actions/presentation/action_panel.dart';
import 'features/auth/data/auth_mode.dart';
import 'features/auth/data/demo_auth_provider.dart';
import 'features/auth/presentation/auth_panel.dart';
import 'features/auth/presentation/better_auth_panel.dart';
import 'features/local_first/data/local_first_support.dart';
import 'features/local_first/presentation/local_first_panel.dart';
import 'features/messages/presentation/private_messages_panel.dart';
import 'features/messages/presentation/public_messages_panel.dart';
import 'features/tasks/presentation/tasks_board_panel.dart';

void runDemoApp() {
  runApp(const ConvexFlutterDemoApp());
}

class ConvexFlutterDemoApp extends StatefulWidget {
  const ConvexFlutterDemoApp({
    super.key,
    this.deploymentUrlOverride,
    this.initialTokenOverride,
  });

  final String? deploymentUrlOverride;
  final String? initialTokenOverride;

  @override
  State<ConvexFlutterDemoApp> createState() => _ConvexFlutterDemoAppState();
}

class _ConvexFlutterDemoAppState extends State<ConvexFlutterDemoApp> {
  static const String _deploymentDefine = String.fromEnvironment(
    'CONVEX_DEMO_URL',
  );
  static const String _tokenDefine = String.fromEnvironment(
    'CONVEX_DEMO_AUTH_TOKEN',
  );

  late final DemoAuthProvider _demoAuthProvider;
  final DemoReconnectController _reconnectController =
      DemoReconnectController();
  final ValueNotifier<TransitionMetrics?> _latencyNotifier = ValueNotifier<TransitionMetrics?>(null);

  ConvexBetterAuthProvider? _betterAuthProvider;
  ConvexClientWithAuth<BetterAuthSession>? _betterAuthClient;

  AuthMode _authMode = AuthMode.demo;
  ConvexClient? _client;
  ConvexClientWithAuth<DemoUserSession>? _authClient;
  ConvexClientRuntime? _runtime;
  ConvexApi? _api;
  ConvexLocalClient? _localClient;
  LocalConvexRuntimeClient? _localRuntime;
  String? _authStatus;
  String? _localAvailabilityError;
  int _bootstrapGeneration = 0;
  int _selectedTabIndex = 0;

  String get _deploymentUrl =>
      widget.deploymentUrlOverride ?? _deploymentDefine;

  String get _preferredDemoToken {
    final overrideToken = widget.initialTokenOverride?.trim();
    if (overrideToken != null && overrideToken.isNotEmpty) {
      return overrideToken;
    }
    if (_tokenDefine.isNotEmpty) {
      return _tokenDefine;
    }
    return bundledDemoJwt;
  }

  String get _preferredTokenLabel {
    final overrideToken = widget.initialTokenOverride?.trim();
    if (overrideToken != null && overrideToken.isNotEmpty) {
      return 'override token';
    }
    if (_tokenDefine.isNotEmpty) {
      return 'startup token';
    }
    return 'bundled demo token';
  }

  @override
  void initState() {
    super.initState();
    _demoAuthProvider = DemoAuthProvider(
      preferredToken: _preferredDemoToken,
      tokenLabel: _preferredTokenLabel,
    );
    if (_deploymentUrl.isNotEmpty) {
      unawaited(_bootstrapClient(_deploymentUrl));
    }
  }

  @override
  void dispose() {
    _disposeClient();
    _demoAuthProvider.dispose();
    _latencyNotifier.dispose();
    super.dispose();
  }

  Future<void> _runAuthOperation(
    Future<void> Function(ConvexClientWithAuth<DemoUserSession> authClient)
    operation,
  ) async {
    final authClient = _authClient;
    if (authClient == null) {
      setState(() {
        _authStatus = 'Set CONVEX_DEMO_URL before using the auth demo.';
      });
      return;
    }

    setState(() {
      _authStatus = null;
    });

    try {
      await operation(authClient);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _authStatus = error.toString();
      });
    }
  }

  Future<void> _login() => _runAuthOperation((authClient) async {
    final session = await authClient.login();
    _demoAuthProvider.recordUiEvent(
      'UI login completed for ${session.displayName}.',
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _authStatus =
          'Logged in as ${session.displayName} using '
          '${session.tokenLabel}.';
    });
  });

  Future<void> _loginFromCache() => _runAuthOperation((authClient) async {
    final session = await authClient.loginFromCache();
    if (!mounted) {
      return;
    }
    setState(() {
      _authStatus =
          'Cached session restored. Refresh count: '
          '${session.cacheRestoreCount}.';
    });
  });

  Future<void> _logout() => _runAuthOperation((authClient) async {
    await authClient.logout();
    if (!mounted) {
      return;
    }
    setState(() {
      _authStatus =
          'Logged out. Cached session is retained for Login From Cache.';
    });
  });

  Future<void> _forceReconnect() async {
    final client = _client;
    if (client == null) {
      setState(() {
        _authStatus = 'Set CONVEX_DEMO_URL before forcing reconnect.';
      });
      return;
    }
    if (!_reconnectController.canForceReconnect &&
        client.currentConnectionState != ConvexConnectionState.connected) {
      setState(() {
        _authStatus = 'Wait for a live connection before forcing reconnect.';
      });
      return;
    }

    setState(() {
      _authStatus =
          'Forced reconnect requested. Watch connection state and cache '
          'refresh calls.';
    });
    _demoAuthProvider.recordUiEvent('UI requested a forced reconnect.');

    try {
      await _reconnectController.forceReconnect();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _authStatus = error.toString();
      });
    }
  }

  void _switchAuthMode(AuthMode mode) {
    if (mode == _authMode) return;
    setState(() {
      _authMode = mode;
      _authStatus = null;
    });
    if (_deploymentUrl.isNotEmpty) {
      unawaited(_bootstrapClient(_deploymentUrl));
    }
  }

  Future<void> _bootstrapClient(String url) async {
    final generation = ++_bootstrapGeneration;
    _disposeClient();

    final client = ConvexClient(
      url,
      config: ConvexClientConfig(
        adapterFactory: _reconnectController.createAdapter,
      ),
      onTransitionMetrics: (metrics) {
        _latencyNotifier.value = metrics;
      },
    );
    // Only create the demo auth client in Demo mode.
    // In Better Auth mode, the _BetterAuthConvexBridge widget handles wiring.
    final authClient = _authMode == AuthMode.demo
        ? client.withAuth<DemoUserSession>(_demoAuthProvider)
        : null;

    // Better Auth: create provider and auth client.
    ConvexBetterAuthProvider? betterAuthProvider;
    ConvexClientWithAuth<BetterAuthSession>? betterAuthClient;
    if (_authMode == AuthMode.betterAuth) {
      betterAuthProvider = ConvexBetterAuthProvider(
        client: BetterAuthClient(baseUrl: url),
      );
      betterAuthClient =
          client.withAuth<BetterAuthSession>(betterAuthProvider);
    }
    final runtime = ConvexClientRuntime(client, disposeClient: false);
    final api = ConvexApi(client);
    ConvexLocalClient? localClient;
    LocalConvexRuntimeClient? localRuntime;
    String? localAvailabilityError;

    try {
      final store = await SqliteLocalStore.open('dartvex_demo.sqlite');
      localClient = await ConvexLocalClient.open(
        client: client,
        config: LocalClientConfig(
          cacheStorage: store,
          queueStorage: store,
          mutationHandlers: buildLocalFirstHandlers(),
        ),
      );
      localRuntime = LocalConvexRuntimeClient(localClient);
    } catch (error) {
      localAvailabilityError = error.toString();
    }

    if (!mounted || generation != _bootstrapGeneration) {
      localRuntime?.dispose();
      await localClient?.dispose();
      runtime.dispose();
      betterAuthClient?.dispose();
      betterAuthProvider?.client.close();
      authClient?.dispose();
      return;
    }

    setState(() {
      _client = client;
      _authClient = authClient;
      _betterAuthProvider = betterAuthProvider;
      _betterAuthClient = betterAuthClient;
      _runtime = runtime;
      _api = api;
      _localClient = localClient;
      _localRuntime = localRuntime;
      _authStatus = _authMode == AuthMode.demo
          ? 'Demo auth ready. Login uses $_preferredTokenLabel.'
          : null;
      _localAvailabilityError = localAvailabilityError;
    });
  }

  void _disposeClient() {
    _localRuntime?.dispose();
    _localRuntime = null;
    if (_localClient != null) {
      unawaited(_localClient!.dispose());
    }
    _localClient = null;
    _localAvailabilityError = null;
    _runtime?.dispose();
    _runtime = null;
    _betterAuthClient?.dispose();
    _betterAuthClient = null;
    _betterAuthProvider?.client.close();
    _betterAuthProvider = null;
    _authClient?.dispose();
    _authClient = null;
    _client = null;
    _api = null;
  }

  Widget _buildHome() {
    return DemoHomePage(
      api: _api,
      authClient: _authClient,
      betterAuthProvider: _betterAuthProvider,
      betterAuthClient: _betterAuthClient,
      demoAuthProvider: _demoAuthProvider,
      localClient: _localClient,
      localRuntime: _localRuntime,
      deploymentUrl: _deploymentUrl,
      authStatus: _authStatus,
      localAvailabilityError: _localAvailabilityError,
      authMode: _authMode,
      selectedTabIndex: _selectedTabIndex,
      onTabChanged: (index) => setState(() => _selectedTabIndex = index),
      onLogin: _login,
      onLoginFromCache: _loginFromCache,
      onLogout: _logout,
      onForceReconnect: _forceReconnect,
      onAuthModeChanged: _switchAuthMode,
      latencyNotifier: _latencyNotifier,
    );
  }

  @override
  Widget build(BuildContext context) {
    final runtime = _runtime ?? const UnavailableRuntimeClient();
    Widget app = MaterialApp(
      title: 'Convex Flutter Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF818CF8),
          brightness: Brightness.dark,
        ).copyWith(
          surface: const Color(0xFF1A1F2E),
          onSurface: const Color(0xFFF3F4F6),
        ),
        scaffoldBackgroundColor: const Color(0xFF0F1419),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0F1419),
          foregroundColor: Color(0xFFF3F4F6),
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF1A1F2E),
          margin: EdgeInsets.zero,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Color(0xFF2D3748)),
          ),
        ),
        dividerTheme: const DividerThemeData(
          space: 1,
          thickness: 1,
          color: Color(0xFF2D3748),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFF141922),
          indicatorColor: const Color(0xFF818CF8).withValues(alpha: 0.2),
          labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>(
            (states) => TextStyle(
              color: states.contains(WidgetState.selected)
                  ? const Color(0xFFF3F4F6)
                  : const Color(0xFF6B7280),
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1A1F2E),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
          labelStyle: const TextStyle(color: Color(0xFFA0A9B8)),
          hintStyle: const TextStyle(color: Color(0xFF6B7280)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFF2D3748)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFF2D3748)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFF818CF8), width: 1.4),
          ),
        ),
        chipTheme: ChipThemeData(
          side: BorderSide.none,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            foregroundColor: const Color(0xFFA0A9B8),
            side: const BorderSide(color: Color(0xFF2D3748)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF818CF8),
          ),
        ),
      ),
      home: _buildHome(),
    );
    if (_authMode == AuthMode.demo && _authClient != null) {
      app = ConvexAuthProvider<DemoUserSession>(
        client: _authClient!,
        child: app,
      );
    }
    if (_authMode == AuthMode.betterAuth && _betterAuthClient != null) {
      app = ConvexAuthProvider<BetterAuthSession>(
        client: _betterAuthClient!,
        child: app,
      );
    }
    app = ConvexProvider(client: runtime, child: app);
    return app;
  }
}

class DemoHomePage extends StatefulWidget {
  const DemoHomePage({
    super.key,
    required this.api,
    required this.authClient,
    required this.betterAuthProvider,
    required this.betterAuthClient,
    required this.demoAuthProvider,
    required this.localClient,
    required this.localRuntime,
    required this.deploymentUrl,
    required this.authStatus,
    required this.localAvailabilityError,
    required this.authMode,
    required this.selectedTabIndex,
    required this.onTabChanged,
    required this.onLogin,
    required this.onLoginFromCache,
    required this.onLogout,
    required this.onForceReconnect,
    required this.onAuthModeChanged,
    required this.latencyNotifier,
  });

  final ConvexApi? api;
  final ConvexClientWithAuth<DemoUserSession>? authClient;
  final ConvexBetterAuthProvider? betterAuthProvider;
  final ConvexClientWithAuth<BetterAuthSession>? betterAuthClient;
  final DemoAuthProvider demoAuthProvider;
  final ConvexLocalClient? localClient;
  final LocalConvexRuntimeClient? localRuntime;
  final String deploymentUrl;
  final String? authStatus;
  final String? localAvailabilityError;
  final AuthMode authMode;
  final int selectedTabIndex;
  final ValueChanged<int> onTabChanged;
  final Future<void> Function() onLogin;
  final Future<void> Function() onLoginFromCache;
  final Future<void> Function() onLogout;
  final Future<void> Function() onForceReconnect;
  final ValueChanged<AuthMode> onAuthModeChanged;
  final ValueNotifier<TransitionMetrics?> latencyNotifier;

  @override
  State<DemoHomePage> createState() => _DemoHomePageState();
}

class _DemoHomePageState extends State<DemoHomePage> {
  int get _selectedIndex => widget.selectedTabIndex;
  set _selectedIndex(int value) => widget.onTabChanged(value);

  List<_DemoDestination> get _destinations => <_DemoDestination>[
    const _DemoDestination(
      label: 'Chats',
      icon: Icons.chat_bubble_outline_rounded,
      selectedIcon: Icons.chat_rounded,
    ),
    const _DemoDestination(
      label: 'Tasks',
      icon: Icons.dashboard_outlined,
      selectedIcon: Icons.dashboard_rounded,
    ),
    const _DemoDestination(
      label: 'Auth',
      icon: Icons.verified_user_outlined,
      selectedIcon: Icons.verified_user_rounded,
    ),
    const _DemoDestination(
      label: 'Local',
      icon: Icons.offline_bolt_outlined,
      selectedIcon: Icons.offline_bolt_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final screens = <Widget>[
      _ChatsScreen(
        api: widget.api,
        deploymentUrl: widget.deploymentUrl,
        latencyNotifier: widget.latencyNotifier,
      ),
      _TasksScreen(
        api: widget.api,
        deploymentUrl: widget.deploymentUrl,
        latencyNotifier: widget.latencyNotifier,
      ),
      _SessionScreen(
        api: widget.api,
        authClient: widget.authClient,
        betterAuthProvider: widget.betterAuthProvider,
        betterAuthClient: widget.betterAuthClient,
        demoAuthProvider: widget.demoAuthProvider,
        deploymentUrl: widget.deploymentUrl,
        authStatus: widget.authStatus,
        authMode: widget.authMode,
        onLogin: widget.onLogin,
        onLoginFromCache: widget.onLoginFromCache,
        onLogout: widget.onLogout,
        onForceReconnect: widget.onForceReconnect,
        onAuthModeChanged: widget.onAuthModeChanged,
        latencyNotifier: widget.latencyNotifier,
      ),
      _LocalScreen(
        localClient: widget.localClient,
        localRuntime: widget.localRuntime,
        deploymentUrl: widget.deploymentUrl,
        availabilityError: widget.localAvailabilityError,
        latencyNotifier: widget.latencyNotifier,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 960;
        return Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          bottomNavigationBar: isWide
              ? null
              : NavigationBar(
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: (index) {
                    _selectedIndex = index;
                  },
                  destinations: _destinations
                      .map(
                        (destination) => NavigationDestination(
                          icon: Icon(destination.icon),
                          selectedIcon: Icon(destination.selectedIcon),
                          label: destination.label,
                        ),
                      )
                      .toList(),
                ),
          body: SafeArea(
            child: isWide
                ? Row(
                    children: <Widget>[
                      SizedBox(
                        width: 240,
                        child: _DesktopNavigation(
                          destinations: _destinations,
                          selectedIndex: _selectedIndex,
                          deploymentUrl: widget.deploymentUrl,
                          latencyNotifier: widget.latencyNotifier,
                          onSelected: (index) {
                            _selectedIndex = index;
                          },
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: IndexedStack(
                          index: _selectedIndex,
                          children: screens,
                        ),
                      ),
                    ],
                  )
                : IndexedStack(index: _selectedIndex, children: screens),
          ),
        );
      },
    );
  }
}

class _ChatsScreen extends StatelessWidget {
  const _ChatsScreen({
    required this.api,
    required this.deploymentUrl,
    required this.latencyNotifier,
  });

  final ConvexApi? api;
  final String deploymentUrl;
  final ValueNotifier<TransitionMetrics?> latencyNotifier;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1040;
        if (isWide) {
          return Scaffold(
            appBar: _DemoAppBar(
              title: 'Chats',
              subtitle: _deploymentSubtitle(deploymentUrl),
              latencyNotifier: latencyNotifier,
            ),
            body: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: PublicMessagesPanel(api: api)),
                  const SizedBox(width: 16),
                  Expanded(child: PrivateMessagesPanel(api: api)),
                ],
              ),
            ),
          );
        }

        return DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: _DemoAppBar(
              title: 'Chats',
              subtitle: _deploymentSubtitle(deploymentUrl),
              latencyNotifier: latencyNotifier,
              bottom: const TabBar(
                tabs: <Widget>[
                  Tab(text: 'Public'),
                  Tab(text: 'Private'),
                ],
              ),
            ),
            body: TabBarView(
              children: <Widget>[
                SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  child: PublicMessagesPanel(api: api),
                ),
                SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  child: PrivateMessagesPanel(api: api),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TasksScreen extends StatelessWidget {
  const _TasksScreen({
    required this.api,
    required this.deploymentUrl,
    required this.latencyNotifier,
  });

  final ConvexApi? api;
  final String deploymentUrl;
  final ValueNotifier<TransitionMetrics?> latencyNotifier;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _DemoAppBar(
        title: 'Tasks',
        subtitle: _deploymentSubtitle(deploymentUrl),
        latencyNotifier: latencyNotifier,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        child: TasksBoardPanel(api: api),
      ),
    );
  }
}

class _SessionScreen extends StatelessWidget {
  const _SessionScreen({
    required this.api,
    required this.authClient,
    required this.betterAuthProvider,
    required this.betterAuthClient,
    required this.demoAuthProvider,
    required this.deploymentUrl,
    required this.authStatus,
    required this.authMode,
    required this.onLogin,
    required this.onLoginFromCache,
    required this.onLogout,
    required this.onForceReconnect,
    required this.onAuthModeChanged,
    required this.latencyNotifier,
  });

  final ConvexApi? api;
  final ConvexClientWithAuth<DemoUserSession>? authClient;
  final ConvexBetterAuthProvider? betterAuthProvider;
  final ConvexClientWithAuth<BetterAuthSession>? betterAuthClient;
  final DemoAuthProvider demoAuthProvider;
  final String deploymentUrl;
  final String? authStatus;
  final AuthMode authMode;
  final Future<void> Function() onLogin;
  final Future<void> Function() onLoginFromCache;
  final Future<void> Function() onLogout;
  final Future<void> Function() onForceReconnect;
  final ValueChanged<AuthMode> onAuthModeChanged;
  final ValueNotifier<TransitionMetrics?> latencyNotifier;

  Widget _buildAuthPanel() {
    if (authMode == AuthMode.betterAuth) {
      final provider = betterAuthProvider;
      if (provider != null && deploymentUrl.isNotEmpty) {
        return BetterAuthPanel(
          provider: provider,
          authClient: betterAuthClient,
        );
      }
      return const BetterAuthSetupPanel();
    }
    return AuthPanel(
      api: api,
      authClient: authClient,
      demoAuthProvider: demoAuthProvider,
      authStatus: authStatus,
      onLogin: onLogin,
      onLoginFromCache: onLoginFromCache,
      onLogout: onLogout,
      onForceReconnect: onForceReconnect,
    );
  }

  @override
  Widget build(BuildContext context) {
    final modeSelector = _AuthModeSelector(
      mode: authMode,
      onChanged: onAuthModeChanged,
    );
    final authPanel = _buildAuthPanel();

    return Scaffold(
      appBar: _DemoAppBar(
        title: 'Auth',
        subtitle: _deploymentSubtitle(deploymentUrl),
        latencyNotifier: latencyNotifier,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 1040;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                modeSelector,
                const SizedBox(height: 16),
                if (isWide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(child: authPanel),
                      const SizedBox(width: 16),
                      Expanded(child: ActionPanel(api: api)),
                    ],
                  )
                else ...<Widget>[
                  authPanel,
                  const SizedBox(height: 16),
                  ActionPanel(api: api),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _LocalScreen extends StatelessWidget {
  const _LocalScreen({
    required this.localClient,
    required this.localRuntime,
    required this.deploymentUrl,
    required this.availabilityError,
    required this.latencyNotifier,
  });

  final ConvexLocalClient? localClient;
  final LocalConvexRuntimeClient? localRuntime;
  final String deploymentUrl;
  final String? availabilityError;
  final ValueNotifier<TransitionMetrics?> latencyNotifier;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _DemoAppBar(
        title: 'Local',
        subtitle: _deploymentSubtitle(deploymentUrl),
        latencyNotifier: latencyNotifier,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        child: LocalFirstPanel(
          client: localClient,
          runtime: localRuntime,
          availabilityError: availabilityError,
        ),
      ),
    );
  }
}

class _DemoAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _DemoAppBar({
    required this.title,
    required this.subtitle,
    this.bottom,
    this.latencyNotifier,
  });

  final String title;
  final String subtitle;
  final PreferredSizeWidget? bottom;
  final ValueNotifier<TransitionMetrics?>? latencyNotifier;

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: false,
      titleSpacing: 20,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF6B7280),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Center(child: _ConnectionChip(latencyNotifier: latencyNotifier)),
        ),
      ],
      bottom: bottom,
    );
  }
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({this.latencyNotifier});

  final ValueNotifier<TransitionMetrics?>? latencyNotifier;

  @override
  Widget build(BuildContext context) {
    return ConvexConnectionBuilder(
      builder: (context, state) {
        final (label, color) = switch (state) {
          ConvexConnectionState.connected => (
            'Connected',
            const Color(0xFF10B981),
          ),
          ConvexConnectionState.connecting => (
            'Connecting',
            const Color(0xFF818CF8),
          ),
          ConvexConnectionState.reconnecting => (
            'Reconnecting',
            const Color(0xFF818CF8),
          ),
          ConvexConnectionState.disconnected => (
            'Disconnected',
            const Color(0xFFF59E0B),
          ),
        };

        final notifier = latencyNotifier;
        Widget chip = DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.18)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.circle, size: 10, color: color),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (notifier != null) ...<Widget>[
                  const SizedBox(width: 8),
                  ValueListenableBuilder<TransitionMetrics?>(
                    valueListenable: notifier,
                    builder: (context, metrics, _) {
                      if (metrics == null) return const SizedBox.shrink();
                      return Text(
                        '${metrics.transitTimeMs.round()}ms',
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: color.withValues(alpha: 0.7),
                          fontWeight: FontWeight.w600,
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        );
        return chip;
      },
    );
  }
}

class _DesktopNavigation extends StatelessWidget {
  const _DesktopNavigation({
    required this.destinations,
    required this.selectedIndex,
    required this.deploymentUrl,
    required this.onSelected,
    this.latencyNotifier,
  });

  final List<_DemoDestination> destinations;
  final int selectedIndex;
  final String deploymentUrl;
  final ValueChanged<int> onSelected;
  final ValueNotifier<TransitionMetrics?>? latencyNotifier;

  @override
  Widget build(BuildContext context) {
    final host = _deploymentHost(deploymentUrl);
    return ColoredBox(
      color: const Color(0xFF141922),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Convex Demo',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              host ?? 'Set CONVEX_DEMO_URL to connect a live backend.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 24),
            for (
              var index = 0;
              index < destinations.length;
              index++
            ) ...<Widget>[
              _RailDestinationTile(
                destination: destinations[index],
                selected: index == selectedIndex,
                onTap: () => onSelected(index),
              ),
              const SizedBox(height: 8),
            ],
            const Spacer(),
            _ConnectionChip(latencyNotifier: latencyNotifier),
          ],
        ),
      ),
    );
  }
}

class _RailDestinationTile extends StatelessWidget {
  const _RailDestinationTile({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _DemoDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              selected ? destination.selectedIcon : destination.icon,
              color: selected ? scheme.primary : const Color(0xFF6B7280),
            ),
            const SizedBox(width: 12),
            Text(
              destination.label,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: selected ? scheme.primary : const Color(0xFFA0A9B8),
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _deploymentSubtitle(String deploymentUrl) {
  final host = _deploymentHost(deploymentUrl);
  return host ?? 'Set CONVEX_DEMO_URL to connect a live backend.';
}

String? _deploymentHost(String deploymentUrl) {
  if (deploymentUrl.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(deploymentUrl);
  return uri?.host ?? deploymentUrl;
}

class _DemoDestination {
  const _DemoDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

// ---------------------------------------------------------------------------
// Auth mode selector
// ---------------------------------------------------------------------------

class _AuthModeSelector extends StatelessWidget {
  const _AuthModeSelector({
    required this.mode,
    required this.onChanged,
  });

  final AuthMode mode;
  final ValueChanged<AuthMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: SegmentedButton<AuthMode>(
            segments: <ButtonSegment<AuthMode>>[
              const ButtonSegment<AuthMode>(
                value: AuthMode.demo,
                label: Text('Demo'),
                icon: Icon(Icons.science_outlined),
              ),
              const ButtonSegment<AuthMode>(
                value: AuthMode.betterAuth,
                label: Text('Better Auth'),
                icon: Icon(Icons.lock_outlined),
              ),
            ],
            selected: <AuthMode>{mode},
            onSelectionChanged: (selected) => onChanged(selected.first),
          ),
        ),
      ],
    );
  }
}

