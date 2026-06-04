import 'dart:async';

import 'package:dartvex_auth_better/dartvex_auth_better.dart';
import 'package:dartvex/dartvex.dart';
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:dartvex_local/dartvex_local.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../convex_api/api.dart';
import 'core/bundled_demo_token.dart';
import 'core/demo_reconnect_controller.dart';
import 'core/local_store_path.dart';
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
import 'features/shared/presentation/concierge_design.dart';
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
  final ValueNotifier<TransitionMetrics?> _latencyNotifier =
      ValueNotifier<TransitionMetrics?>(null);
  final TextEditingController _betterAuthNameController =
      TextEditingController();
  final TextEditingController _betterAuthEmailController =
      TextEditingController();
  final TextEditingController _betterAuthPasswordController =
      TextEditingController();

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
    _betterAuthNameController.dispose();
    _betterAuthEmailController.dispose();
    _betterAuthPasswordController.dispose();
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
          'Logged out. Cached session is retained for Restore Session.';
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
        connectivitySignal: ConnectivityPlusSignal(),
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
      betterAuthClient = client.withAuth<BetterAuthSession>(betterAuthProvider);
    }
    final runtime = ConvexClientRuntime(client, disposeClient: false);
    final api = ConvexApi(client);
    ConvexLocalClient? localClient;
    LocalConvexRuntimeClient? localRuntime;
    String? localAvailabilityError;

    try {
      final store = await SqliteLocalStore.open(await resolveLocalStorePath());
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
      betterAuthNameController: _betterAuthNameController,
      betterAuthEmailController: _betterAuthEmailController,
      betterAuthPasswordController: _betterAuthPasswordController,
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
      title: 'Dartvex Demo',
      debugShowCheckedModeBanner: false,
      theme: buildConciergeTheme(),
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
    required this.betterAuthNameController,
    required this.betterAuthEmailController,
    required this.betterAuthPasswordController,
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
  final TextEditingController betterAuthNameController;
  final TextEditingController betterAuthEmailController;
  final TextEditingController betterAuthPasswordController;
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
    const _DemoDestination(
      label: 'About',
      icon: Icons.info_outline_rounded,
      selectedIcon: Icons.info_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final screens = <Widget>[
      _ChatsScreen(
        api: widget.api,
        deploymentUrl: widget.deploymentUrl,
        authMode: widget.authMode,
        authProviderReady: _authProviderReady,
        latencyNotifier: widget.latencyNotifier,
      ),
      _TasksScreen(
        api: widget.api,
        deploymentUrl: widget.deploymentUrl,
        authMode: widget.authMode,
        authProviderReady: _authProviderReady,
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
        authProviderReady: _authProviderReady,
        betterAuthNameController: widget.betterAuthNameController,
        betterAuthEmailController: widget.betterAuthEmailController,
        betterAuthPasswordController: widget.betterAuthPasswordController,
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
        authMode: widget.authMode,
        authProviderReady: _authProviderReady,
        availabilityError: widget.localAvailabilityError,
        latencyNotifier: widget.latencyNotifier,
      ),
      _AboutScreen(
        authMode: widget.authMode,
        authProviderReady: _authProviderReady,
        latencyNotifier: widget.latencyNotifier,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 960;
        return Scaffold(
          backgroundColor: ConciergeColors.background,
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
            child: ConciergeBackground(
              child: isWide
                  ? Row(
                      children: <Widget>[
                        SizedBox(
                          width: 288,
                          child: _DesktopNavigation(
                            destinations: _destinations,
                            selectedIndex: _selectedIndex,
                            deploymentUrl: widget.deploymentUrl,
                            authMode: widget.authMode,
                            authProviderReady: _authProviderReady,
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
          ),
        );
      },
    );
  }

  bool get _authProviderReady {
    return switch (widget.authMode) {
      AuthMode.demo => widget.authClient != null,
      AuthMode.betterAuth => widget.betterAuthClient != null,
    };
  }
}

class _ChatsScreen extends StatelessWidget {
  const _ChatsScreen({
    required this.api,
    required this.deploymentUrl,
    required this.authMode,
    required this.authProviderReady,
    required this.latencyNotifier,
  });

  final ConvexApi? api;
  final String deploymentUrl;
  final AuthMode authMode;
  final bool authProviderReady;
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
              authMode: authMode,
              authProviderReady: authProviderReady,
              latencyNotifier: latencyNotifier,
            ),
            body: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: PublicMessagesPanel(api: api)),
                  const SizedBox(width: 20),
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
              authMode: authMode,
              authProviderReady: authProviderReady,
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
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
                  child: PublicMessagesPanel(api: api),
                ),
                SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
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
    required this.authMode,
    required this.authProviderReady,
    required this.latencyNotifier,
  });

  final ConvexApi? api;
  final String deploymentUrl;
  final AuthMode authMode;
  final bool authProviderReady;
  final ValueNotifier<TransitionMetrics?> latencyNotifier;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _DemoAppBar(
        title: 'Tasks',
        subtitle: _deploymentSubtitle(deploymentUrl),
        authMode: authMode,
        authProviderReady: authProviderReady,
        latencyNotifier: latencyNotifier,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
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
    required this.authProviderReady,
    required this.betterAuthNameController,
    required this.betterAuthEmailController,
    required this.betterAuthPasswordController,
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
  final bool authProviderReady;
  final TextEditingController betterAuthNameController;
  final TextEditingController betterAuthEmailController;
  final TextEditingController betterAuthPasswordController;
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
          nameController: betterAuthNameController,
          emailController: betterAuthEmailController,
          passwordController: betterAuthPasswordController,
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
        authMode: authMode,
        authProviderReady: authProviderReady,
        latencyNotifier: latencyNotifier,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 1040;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                modeSelector,
                const SizedBox(height: 20),
                if (isWide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(child: authPanel),
                      const SizedBox(width: 20),
                      Expanded(child: ActionPanel(api: api)),
                    ],
                  )
                else ...<Widget>[
                  authPanel,
                  const SizedBox(height: 20),
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
    required this.authMode,
    required this.authProviderReady,
    required this.availabilityError,
    required this.latencyNotifier,
  });

  final ConvexLocalClient? localClient;
  final LocalConvexRuntimeClient? localRuntime;
  final String deploymentUrl;
  final AuthMode authMode;
  final bool authProviderReady;
  final String? availabilityError;
  final ValueNotifier<TransitionMetrics?> latencyNotifier;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _DemoAppBar(
        title: 'Local',
        subtitle: _deploymentSubtitle(deploymentUrl),
        authMode: authMode,
        authProviderReady: authProviderReady,
        latencyNotifier: latencyNotifier,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        child: LocalFirstPanel(
          client: localClient,
          runtime: localRuntime,
          demoConfigured: deploymentUrl.isNotEmpty,
          availabilityError: availabilityError,
        ),
      ),
    );
  }
}

class _AboutScreen extends StatelessWidget {
  const _AboutScreen({
    required this.authMode,
    required this.authProviderReady,
    required this.latencyNotifier,
  });

  static const String _website = 'https://andrefrelicot.dev';
  static const String _github = 'https://github.com/AndreFrelicot/dartvex/';

  final AuthMode authMode;
  final bool authProviderReady;
  final ValueNotifier<TransitionMetrics?> latencyNotifier;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: _DemoAppBar(
        title: 'About',
        subtitle: 'Dartvex Flutter SDK',
        authMode: authMode,
        authProviderReady: authProviderReady,
        latencyNotifier: latencyNotifier,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Container(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: <Color>[
                    Color(0xFF1C2636),
                    ConciergeColors.surfaceLow,
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: ConciergeColors.cyan.withValues(alpha: 0.16),
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: ConciergeColors.surfaceLowest.withValues(
                      alpha: 0.48,
                    ),
                    blurRadius: 32,
                    offset: const Offset(0, 18),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 30,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    const DartvexLogoMark(size: 140, padding: 8, glow: true),
                    const SizedBox(height: 22),
                    Text(
                      'Dartvex',
                      textAlign: TextAlign.center,
                      style: textTheme.headlineMedium?.copyWith(
                        color: ConciergeColors.cyanSoft,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Flutter demo app for the Dartvex SDK.',
                      textAlign: TextAlign.center,
                      style: textTheme.bodyLarge?.copyWith(
                        color: ConciergeColors.textMuted,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 22),
                    _AboutInfoLine(
                      icon: Icons.copyright_rounded,
                      label: 'Copyright © 2026 André Frélicot',
                    ),
                    const SizedBox(height: 10),
                    const _AboutInfoLine(
                      icon: Icons.balance_rounded,
                      label: 'MIT License',
                    ),
                    const SizedBox(height: 10),
                    const _AboutInfoLine(
                      icon: Icons.link_rounded,
                      label: _website,
                      selectable: true,
                    ),
                    const SizedBox(height: 10),
                    const _AboutInfoLine(
                      icon: Icons.code_rounded,
                      label: _github,
                      selectable: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AboutInfoLine extends StatelessWidget {
  const _AboutInfoLine({
    required this.icon,
    required this.label,
    this.selectable = false,
  });

  final IconData icon;
  final String label;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: selectable ? ConciergeColors.cyanSoft : ConciergeColors.textMuted,
      fontWeight: FontWeight.w700,
    );
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          icon,
          size: 18,
          color: selectable
              ? ConciergeColors.cyanSoft
              : ConciergeColors.textMuted,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(label, textAlign: TextAlign.center, style: textStyle),
        ),
      ],
    );

    final decoratedLine = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: ConciergeColors.surfaceHigh.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: ConciergeColors.outline.withValues(alpha: 0.55),
        ),
      ),
      child: content,
    );

    if (!selectable) {
      return decoratedLine;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openExternalUrl(label),
        child: decoratedLine,
      ),
    );
  }
}

Future<void> _openExternalUrl(String rawUrl) async {
  final uri = Uri.parse(rawUrl);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

class _DemoAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _DemoAppBar({
    required this.title,
    required this.subtitle,
    required this.authProviderReady,
    this.bottom,
    this.authMode,
    this.latencyNotifier,
  });

  final String title;
  final String subtitle;
  final PreferredSizeWidget? bottom;
  final AuthMode? authMode;
  final bool authProviderReady;
  final ValueNotifier<TransitionMetrics?>? latencyNotifier;

  static const double _toolbarHeight = 96;

  @override
  Size get preferredSize =>
      Size.fromHeight(_toolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: _toolbarHeight,
      titleSpacing: 20,
      flexibleSpace: DecoratedBox(
        decoration: BoxDecoration(
          color: ConciergeColors.surfaceLow.withValues(alpha: 0.96),
          border: Border(
            bottom: BorderSide(
              color: ConciergeColors.outline.withValues(alpha: 0.26),
            ),
          ),
        ),
      ),
      title: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          final titleBlock = Row(
            children: <Widget>[
              const DartvexLogoMark(size: 42, padding: 3),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: ConciergeColors.text,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: ConciergeColors.textDim,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          final statusCluster = Align(
            alignment: compact ? Alignment.centerLeft : Alignment.centerRight,
            child: _HeaderStatusCluster(
              authMode: authMode,
              authProviderReady: authProviderReady,
              latencyNotifier: latencyNotifier,
            ),
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                titleBlock,
                const SizedBox(height: 8),
                statusCluster,
              ],
            );
          }

          return Row(
            children: <Widget>[
              Expanded(child: titleBlock),
              const SizedBox(width: 16),
              Flexible(child: statusCluster),
            ],
          );
        },
      ),
      bottom: bottom,
    );
  }
}

class _HeaderStatusCluster extends StatelessWidget {
  const _HeaderStatusCluster({
    required this.authProviderReady,
    this.authMode,
    this.latencyNotifier,
  });

  final AuthMode? authMode;
  final bool authProviderReady;
  final ValueNotifier<TransitionMetrics?>? latencyNotifier;

  @override
  Widget build(BuildContext context) {
    return ConvexConnectionBuilder(
      builder: (context, state) {
        final (label, color) = switch (state) {
          ConvexConnectionState.connected => (
            'Realtime online',
            ConciergeColors.success,
          ),
          ConvexConnectionState.connecting => (
            'Realtime connecting',
            ConciergeColors.cyan,
          ),
          ConvexConnectionState.reconnecting => (
            'Realtime reconnecting',
            ConciergeColors.cyan,
          ),
          ConvexConnectionState.disconnected => (
            'Realtime offline',
            ConciergeColors.warning,
          ),
          ConvexConnectionState.fatalError => (
            'Realtime unavailable',
            ConciergeColors.warning,
          ),
        };

        // Latency only makes sense while the realtime socket is connected.
        // During reconnecting/connecting/offline the value is stale, so we
        // hide the trailing "<n>ms" badge entirely.
        final showLatency = state == ConvexConnectionState.connected;
        final notifier = latencyNotifier;
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          alignment: WrapAlignment.end,
          children: <Widget>[
            _HeaderStatusPill(
              icon: Icons.sync_rounded,
              label: label,
              color: color,
              trailing: (notifier == null || !showLatency)
                  ? null
                  : ValueListenableBuilder<TransitionMetrics?>(
                      valueListenable: notifier,
                      builder: (context, metrics, _) {
                        if (metrics == null) return const SizedBox.shrink();
                        return Text(
                          '${metrics.transitTimeMs.round()}ms',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: color.withValues(alpha: 0.72),
                                fontWeight: FontWeight.w700,
                              ),
                        );
                      },
                    ),
            ),
            if (authMode != null)
              _AuthHeaderPill(
                authMode: authMode!,
                authProviderReady: authProviderReady,
              ),
          ],
        );
      },
    );
  }
}

class _AuthHeaderPill extends StatelessWidget {
  const _AuthHeaderPill({
    required this.authMode,
    required this.authProviderReady,
  });

  final AuthMode authMode;
  final bool authProviderReady;

  @override
  Widget build(BuildContext context) {
    if (!authProviderReady) {
      return _HeaderStatusPill(
        icon: Icons.verified_user_outlined,
        label: '${_authMechanismLabel(authMode)} auth',
        color: ConciergeColors.textMuted,
        backgroundColor: ConciergeColors.surfaceHigh,
        borderColor: ConciergeColors.outline.withValues(alpha: 0.5),
      );
    }

    return switch (authMode) {
      AuthMode.demo => ConvexAuthBuilder<DemoUserSession>(
        builder: (context, state) => _HeaderStatusPill(
          icon: Icons.verified_user_outlined,
          label: 'Demo: ${_compactAuthStateLabel(state)}',
          color: _compactAuthStateColor(state),
          backgroundColor: _compactAuthStateBackground(state),
          borderColor: _compactAuthStateColor(state).withValues(alpha: 0.22),
        ),
      ),
      AuthMode.betterAuth => ConvexAuthBuilder<BetterAuthSession>(
        builder: (context, state) => _HeaderStatusPill(
          icon: Icons.verified_user_outlined,
          label: 'Better Auth: ${_compactAuthStateLabel(state)}',
          color: _compactAuthStateColor(state),
          backgroundColor: _compactAuthStateBackground(state),
          borderColor: _compactAuthStateColor(state).withValues(alpha: 0.22),
        ),
      ),
    };
  }
}

class _HeaderStatusPill extends StatelessWidget {
  const _HeaderStatusPill({
    required this.icon,
    required this.label,
    required this.color,
    this.backgroundColor,
    this.borderColor,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color? backgroundColor;
  final Color? borderColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor ?? color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor ?? color.withValues(alpha: 0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 6),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class _DesktopNavigation extends StatelessWidget {
  const _DesktopNavigation({
    required this.destinations,
    required this.selectedIndex,
    required this.deploymentUrl,
    required this.authMode,
    required this.authProviderReady,
    required this.onSelected,
    this.latencyNotifier,
  });

  final List<_DemoDestination> destinations;
  final int selectedIndex;
  final String deploymentUrl;
  final AuthMode authMode;
  final bool authProviderReady;
  final ValueChanged<int> onSelected;
  final ValueNotifier<TransitionMetrics?>? latencyNotifier;

  @override
  Widget build(BuildContext context) {
    final host = _deploymentHost(deploymentUrl);
    return Container(
      decoration: BoxDecoration(
        color: ConciergeColors.surfaceLow.withValues(alpha: 0.96),
        border: Border(
          right: BorderSide(
            color: ConciergeColors.outline.withValues(alpha: 0.28),
          ),
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: ConciergeColors.surfaceLowest.withValues(alpha: 0.36),
            blurRadius: 28,
            offset: const Offset(12, 0),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const DartvexLogoMark(size: 52, padding: 4, glow: true),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Dartvex',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: ConciergeColors.cyanSoft,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Flutter SDK Demo',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: ConciergeColors.textDim,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              host ?? 'Set CONVEX_DEMO_URL to connect a live backend.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: ConciergeColors.textMuted,
                fontWeight: FontWeight.w600,
                height: 1.35,
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
            _HeaderStatusCluster(
              authMode: authMode,
              authProviderReady: authProviderReady,
              latencyNotifier: latencyNotifier,
            ),
          ],
        ),
      ),
    );
  }
}

String _authMechanismLabel(AuthMode mode) {
  return switch (mode) {
    AuthMode.demo => 'Demo',
    AuthMode.betterAuth => 'Better Auth',
  };
}

String _compactAuthStateLabel<TUser>(AuthState<TUser> state) {
  return switch (state) {
    AuthLoading<TUser>() => 'loading',
    AuthAuthenticated<TUser>() => 'signed in',
    AuthUnauthenticated<TUser>() => 'signed out',
  };
}

Color _compactAuthStateColor<TUser>(AuthState<TUser> state) {
  return switch (state) {
    AuthLoading<TUser>() => ConciergeColors.cyan,
    AuthAuthenticated<TUser>() => ConciergeColors.success,
    AuthUnauthenticated<TUser>() => const Color(0xFFFF8A80),
  };
}

Color _compactAuthStateBackground<TUser>(AuthState<TUser> state) {
  return switch (state) {
    AuthLoading<TUser>() => const Color(0xFF2C1F5C),
    AuthAuthenticated<TUser>() => const Color(0xFF0D3D37),
    AuthUnauthenticated<TUser>() => const Color(0xFF5F1515),
  };
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
      borderRadius: BorderRadius.circular(12),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: 0.24)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              selected ? destination.selectedIcon : destination.icon,
              color: selected ? scheme.primary : ConciergeColors.textDim,
            ),
            const SizedBox(width: 12),
            Text(
              destination.label,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: selected
                    ? ConciergeColors.cyanSoft
                    : ConciergeColors.textMuted,
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
  return host ?? 'No backend URL';
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
  const _AuthModeSelector({required this.mode, required this.onChanged});

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
