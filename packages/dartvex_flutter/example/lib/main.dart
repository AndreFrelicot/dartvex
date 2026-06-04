import 'dart:async';

import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  late final DemoRuntimeClient _client;

  @override
  void initState() {
    super.initState();
    _client = DemoRuntimeClient()
      ..emitConnectionState(ConvexConnectionState.connected);
  }

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConvexProvider(
      client: _client,
      child: MaterialApp(
        title: 'dartvex_flutter example',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF0B7285),
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: const Color(0xFFF7F4EC),
        ),
        home: const ExampleHomePage(),
      ),
    );
  }
}

class ExampleHomePage extends StatelessWidget {
  const ExampleHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('dartvex_flutter'),
        backgroundColor: Colors.transparent,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: <Color>[Color(0xFFF7F4EC), Color(0xFFE5F4F1)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.82),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        child: ConvexConnectionIndicator(
                          connectedBuilder: (context) =>
                              const Text('Connected'),
                          connectingBuilder: (context) =>
                              const Text('Connecting'),
                          disconnectedBuilder: (context) =>
                              const Text('Disconnected'),
                        ),
                      ),
                    ),
                    // Shown only while the client is recovering auth after a
                    // rejection. Backed by ConvexClient.authRefreshing.
                    const AuthRefreshingBadge(),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Realtime messages',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'This example uses an in-memory runtime client to demonstrate '
                'the widget API. Swap it with ConvexClientRuntime in a real app.',
              ),
              const SizedBox(height: 24),
              Expanded(
                child: ConvexQuery<List<String>>(
                  query: 'messages:list',
                  decode: (value) => List<String>.from(value as List<dynamic>),
                  builder: (context, snapshot) {
                    if (snapshot.isLoading) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(child: Text(snapshot.error.toString()));
                    }
                    final messages = snapshot.data ?? const <String>[];
                    return ListView.separated(
                      itemCount: messages.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        return DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.84),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(messages[index]),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 20),
              ConvexMutation<String>(
                mutation: 'messages:send',
                builder: (context, mutate, snapshot) {
                  return FilledButton(
                    onPressed: snapshot.isLoading
                        ? null
                        : () {
                            mutate(<String, dynamic>{
                              'text':
                                  'Message sent at ${DateTime.now().toIso8601String()}',
                            });
                          },
                    child: Text(
                      snapshot.isLoading ? 'Sending...' : 'Send a demo message',
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () {
                  final client = ConvexProvider.of(context);
                  if (client is DemoRuntimeClient) {
                    unawaited(client.simulateAuthRefresh());
                  }
                },
                child: const Text('Simulate auth refresh'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A chip shown only while the client is refreshing auth after a rejection.
///
/// Demonstrates [ConvexAuthRefreshingBuilder] driven by
/// `ConvexClient.authRefreshing`.
class AuthRefreshingBadge extends StatelessWidget {
  /// Creates an [AuthRefreshingBadge].
  const AuthRefreshingBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return ConvexAuthRefreshingBuilder(
      builder: (context, isRefreshing) {
        if (!isRefreshing) {
          return const SizedBox.shrink();
        }
        return DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFFFFF3CD),
            borderRadius: BorderRadius.circular(999),
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('Authenticating…'),
              ],
            ),
          ),
        );
      },
    );
  }
}

class DemoRuntimeClient implements ConvexRuntimeClient {
  DemoRuntimeClient()
    : _connectionController = StreamController<ConvexConnectionState>.broadcast(
        sync: true,
      ) {
    _messages = <String>[
      'Welcome to dartvex_flutter.',
      'This list updates through the shared runtime interface.',
    ];
  }

  final StreamController<ConvexConnectionState> _connectionController;
  final StreamController<bool> _authRefreshingController =
      StreamController<bool>.broadcast(sync: true);
  final List<DemoRuntimeSubscription> _subscriptions =
      <DemoRuntimeSubscription>[];
  late List<String> _messages;
  ConvexConnectionState _currentConnectionState =
      ConvexConnectionState.connecting;
  bool _currentAuthRefreshing = false;
  bool _disposed = false;

  @override
  Stream<ConvexConnectionState> get connectionState =>
      _connectionController.stream;

  @override
  ConvexConnectionState get currentConnectionState => _currentConnectionState;

  @override
  Stream<bool> get authRefreshing => _authRefreshingController.stream;

  @override
  bool get currentAuthRefreshing => _currentAuthRefreshing;

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    return 'Action "$name" completed';
  }

  @override
  Future<void> reconnectNow(String reason) async {}

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    unawaited(_connectionController.close());
    unawaited(_authRefreshingController.close());
  }

  void emitConnectionState(ConvexConnectionState state) {
    _currentConnectionState = state;
    _connectionController.add(state);
  }

  void emitAuthRefreshing(bool isRefreshing) {
    _currentAuthRefreshing = isRefreshing;
    _authRefreshingController.add(isRefreshing);
  }

  /// Simulates the client recovering auth after a server rejection: it flips to
  /// "refreshing" briefly, the way a real reauth (stop socket, refetch token,
  /// restart) would, then settles back.
  Future<void> simulateAuthRefresh() async {
    emitAuthRefreshing(true);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (_disposed) {
      return;
    }
    emitAuthRefreshing(false);
  }

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final text = args['text'] as String? ?? 'Untitled message';
    _messages = <String>[text, ..._messages];
    for (final subscription in _subscriptions) {
      subscription.emit(
        List<String>.from(_messages),
        source: ConvexQuerySource.remote,
      );
    }
    return text;
  }

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    return List<String>.from(_messages);
  }

  @override
  Future<T> queryOnce<T>(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final result = await query(name, args);
    return result as T;
  }

  @override
  ConvexRuntimeSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    final subscription = DemoRuntimeSubscription();
    _subscriptions.add(subscription);
    scheduleMicrotask(() {
      if (!subscription.isCanceled) {
        subscription.emit(List<String>.from(_messages));
      }
    });
    return subscription;
  }
}

class DemoRuntimeSubscription implements ConvexRuntimeSubscription {
  final StreamController<ConvexRuntimeQueryEvent> _controller =
      StreamController<ConvexRuntimeQueryEvent>.broadcast(sync: true);
  bool isCanceled = false;

  @override
  Stream<ConvexRuntimeQueryEvent> get stream => _controller.stream;

  @override
  void cancel() {
    if (isCanceled) {
      return;
    }
    isCanceled = true;
    unawaited(_controller.close());
  }

  void emit(
    dynamic value, {
    ConvexQuerySource source = ConvexQuerySource.remote,
  }) {
    if (isCanceled) {
      return;
    }
    _controller.add(ConvexRuntimeQuerySuccess(value, source: source));
  }
}
