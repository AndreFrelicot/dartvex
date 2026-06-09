import 'package:dartvex/dartvex.dart'
    show
        AuthAuthenticated,
        ConvexClientConfig,
        ConvexPaginationStatus,
        DartvexLogEvent,
        DartvexLogLevel;
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/material.dart';

import '../../../../convex_api/api.dart';
import '../../auth/data/demo_auth_provider.dart' show DemoUserSession;
import '../../shared/presentation/concierge_design.dart';
import '../../shared/presentation/section_card.dart';

/// The "Showcase" tab: six self-contained demos of the SDK capabilities added
/// in the parity work — optimistic updates, reactive pagination, the rich
/// connection status, a read-only reconnect/backoff config readout, the
/// auth-refreshing signal, and the structured logging stream — all driven
/// against the real Convex backend via the widgets in `dartvex_flutter`.
class ShowcasePanel extends StatelessWidget {
  /// Creates a [ShowcasePanel]. [hasBackend] is `false` when `CONVEX_DEMO_URL`
  /// is unset, in which case a configuration notice is shown instead.
  const ShowcasePanel({
    super.key,
    required this.hasBackend,
    required this.logsNotifier,
    this.api,
    this.clientConfig,
    this.onSimulateExpiredToken,
  });

  /// Whether a deployment URL is configured (the live client is available).
  final bool hasBackend;

  /// The generated typed API root, used by the reactive pagination demo.
  /// Non-null whenever [hasBackend] is true (the cards only render then).
  final ConvexApi? api;

  /// Live, bounded ring buffer of structured SDK log events (newest first), fed
  /// by the [DartvexLogger] configured on the client in `app.dart`.
  final ValueNotifier<List<DartvexLogEvent>> logsNotifier;

  /// The live client's config, surfaced read-only by the config readout card.
  /// `null` only before the client has bootstrapped, at which point no cards
  /// render (the [hasBackend] notice shows instead).
  final ConvexClientConfig? clientConfig;

  /// Hands the live client an expired token to exercise the genuine reauth path
  /// (toggling the auth-refreshing badge). `null` outside Demo auth mode; the
  /// auth-refreshing card then shows only the passive badge.
  final Future<void> Function()? onSimulateExpiredToken;

  @override
  Widget build(BuildContext context) {
    if (!hasBackend) {
      return const _BackendRequiredNotice();
    }
    // A non-recycling scroller (not a ListView) so the demo cards' local state
    // — the logs level filter, the "fail next send" toggle, the pagination
    // status/loaded pages — survives scrolling away and back. The set of cards
    // is small and fixed, so building them all eagerly is cheap, and this
    // matches every other screen in the app.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _OptimisticDemoCard(),
          const SizedBox(height: 20),
          _PaginationDemoCard(api: api!),
          const SizedBox(height: 20),
          const _ConnectionStatusDemoCard(),
          const SizedBox(height: 20),
          _ConfigReadoutCard(
            config: clientConfig ?? const ConvexClientConfig(),
          ),
          const SizedBox(height: 20),
          _AuthRefreshingDemoCard(
            onSimulateExpiredToken: onSimulateExpiredToken,
          ),
          const SizedBox(height: 20),
          _LoggingDemoCard(logsNotifier: logsNotifier),
        ],
      ),
    );
  }
}

/// A short "what to watch" caption rendered under each demo's controls.
class _WatchHint extends StatelessWidget {
  const _WatchHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ConciergeColors.cyan.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ConciergeColors.cyan.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.visibility_outlined,
            size: 16,
            color: ConciergeColors.cyanSoft,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: ConciergeColors.cyanSoft,
                fontSize: 12.5,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 1. Optimistic updates
// ---------------------------------------------------------------------------

class _OptimisticDemoCard extends StatefulWidget {
  const _OptimisticDemoCard();

  @override
  State<_OptimisticDemoCard> createState() => _OptimisticDemoCardState();
}

class _OptimisticDemoCardState extends State<_OptimisticDemoCard> {
  final TextEditingController _controller = TextEditingController(
    text: 'Optimistic hello',
  );
  bool _failNext = false;
  String _pendingText = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      eyebrow: 'OPTIMISTIC UPDATES',
      title: 'Instant sends, automatic rollback',
      subtitle:
          'The message appears the instant you tap Send — before the server '
          'confirms — then snaps to confirmed. Toggle "fail next send" to watch '
          'the optimistic value roll back on a server error.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _OptimisticFeed(),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            decoration: const InputDecoration(
              labelText: 'Message',
              hintText: 'Type something to send optimistically',
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Fail the next send (routes to failingSend)'),
            value: _failNext,
            onChanged: (value) => setState(() => _failNext = value),
          ),
          const SizedBox(height: 4),
          ConvexMutation<dynamic>(
            mutation: _failNext
                ? 'messages:failingSend'
                : 'messages:sendPublic',
            optimisticUpdate: (store) {
              final existing =
                  (store.getQuery('messages:listPublic') as List<dynamic>?) ??
                  const <dynamic>[];
              store.setQuery('messages:listPublic', const <String, dynamic>{}, <
                dynamic
              >[
                <String, dynamic>{
                  '_id': 'optimistic',
                  // Double, so the typed decoder in the Chats tab (which shares
                  // this same listPublic query via the IndexedStack) accepts
                  // the overlaid item instead of throwing on an int.
                  '_creationTime': DateTime.now().millisecondsSinceEpoch
                      .toDouble(),
                  'author': 'You',
                  'text': _pendingText,
                  'pending': true,
                },
                ...existing,
              ]);
            },
            builder: (context, mutate, snapshot) {
              return Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: snapshot.isLoading
                          ? null
                          : () {
                              final text = _controller.text.trim();
                              if (text.isEmpty) {
                                return;
                              }
                              _pendingText = text;
                              final messenger = ScaffoldMessenger.of(context);
                              mutate(<String, dynamic>{
                                'author': 'You',
                                'text': text,
                              }).catchError((Object error) {
                                if (mounted) {
                                  messenger.showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Send failed — optimistic value rolled '
                                        'back.',
                                      ),
                                    ),
                                  );
                                }
                                return null;
                              });
                            },
                      icon: Icon(
                        snapshot.isLoading
                            ? Icons.hourglass_top
                            : Icons.bolt_rounded,
                      ),
                      label: Text(
                        snapshot.isLoading ? 'Sending…' : 'Send optimistically',
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          const _WatchHint(
            'The "You" bubble appears instantly with a "pending" tag, then '
            'becomes a normal bubble once the Transition lands — or vanishes if '
            'the send fails.',
          ),
        ],
      ),
    );
  }
}

/// Live view of `messages:listPublic` — the optimistic overlay shows up here
/// because the mutation overlays exactly this query.
class _OptimisticFeed extends StatelessWidget {
  const _OptimisticFeed();

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: ConciergeColors.surfaceLowest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ConciergeColors.cyan.withValues(alpha: 0.12)),
      ),
      padding: const EdgeInsets.all(12),
      child: ConvexQuery<List<Map<String, dynamic>>>(
        query: 'messages:listPublic',
        decode: (value) => (value as List<dynamic>)
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList(),
        builder: (context, snapshot) {
          if (snapshot.isLoading) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                snapshot.error.toString(),
                style: const TextStyle(color: ConciergeColors.danger),
              ),
            );
          }
          final items = snapshot.data ?? const <Map<String, dynamic>>[];
          if (items.isEmpty) {
            return const Center(
              child: Text(
                'No messages yet — send one.',
                style: TextStyle(color: ConciergeColors.textDim),
              ),
            );
          }
          final visible = items.take(6).toList();
          return ListView.separated(
            itemCount: visible.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final item = visible[index];
              final pending = item['pending'] == true;
              return _FeedBubble(
                author: '${item['author'] ?? '—'}',
                text: '${item['text'] ?? ''}',
                pending: pending,
              );
            },
          );
        },
      ),
    );
  }
}

class _FeedBubble extends StatelessWidget {
  const _FeedBubble({
    required this.author,
    required this.text,
    required this.pending,
  });

  final String author;
  final String text;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: pending ? 0.6 : 1,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: ConciergeColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: pending
                ? ConciergeColors.warning.withValues(alpha: 0.5)
                : ConciergeColors.cyan.withValues(alpha: 0.14),
          ),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    author,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      color: ConciergeColors.cyanSoft,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(text),
                ],
              ),
            ),
            if (pending) ...<Widget>[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: ConciergeColors.warning.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'pending',
                  style: TextStyle(
                    color: ConciergeColors.warning,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Reactive pagination
// ---------------------------------------------------------------------------

class _PaginationDemoCard extends StatefulWidget {
  const _PaginationDemoCard({required this.api});

  final ConvexApi api;

  @override
  State<_PaginationDemoCard> createState() => _PaginationDemoCardState();
}

class _PaginationDemoCardState extends State<_PaginationDemoCard> {
  bool _busy = false;
  String? _status;

  Future<void> _run(String action, Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await body();
    } catch (error) {
      if (mounted) {
        setState(() => _status = '$action failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = ConvexProvider.of(context);
    return SectionCard(
      eyebrow: 'REACTIVE PAGINATION',
      title: 'Gapless pages that stay live',
      subtitle:
          'Each page is a real subscription, so loaded pages update in place '
          'and stay gapless across reconnects. Seed the feed, page through it, '
          'then post a message and watch it appear atop page 1 without a reload.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run('Seed', () async {
                        final inserted = await client.mutate(
                          'messages:seedPublic',
                        );
                        final added = inserted is num ? inserted.toInt() : 0;
                        if (mounted) {
                          setState(
                            () => _status = added > 0
                                ? 'Seeded $added message(s).'
                                : 'Feed already populated — seedPublic is '
                                      'idempotent (it tops up to ~42, and '
                                      'the feed is already above that).',
                          );
                        }
                      }),
                icon: const Icon(Icons.dataset_outlined),
                label: const Text('Seed demo feed'),
              ),
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run('Post', () async {
                        await client.mutate('messages:sendPublic', <
                          String,
                          dynamic
                        >{
                          'author': 'Showcase',
                          'text':
                              'Live insert at ${TimeOfDay.now().format(context)}',
                        });
                      }),
                icon: const Icon(Icons.north_east_rounded),
                label: const Text('Post to feed'),
              ),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run('Clear', () async {
                        final cleared = await client.mutate(
                          'messages:clearPublicMessages',
                        );
                        final n = cleared is num ? cleared.toInt() : 0;
                        if (mounted) {
                          setState(() => _status = 'Cleared $n message(s).');
                        }
                      }),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Clear feed'),
              ),
            ],
          ),
          if (_status != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              _status!,
              style: const TextStyle(
                color: ConciergeColors.cyanSoft,
                fontSize: 12.5,
              ),
            ),
          ],
          const SizedBox(height: 14),
          ConvexQuery<int>(
            query: 'messages:countPublic',
            decode: (value) => (value as num).toInt(),
            builder: (context, countSnap) {
              final total = countSnap.data ?? 0;
              return Container(
                height: 340,
                decoration: BoxDecoration(
                  color: ConciergeColors.surfaceLowest.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: ConciergeColors.cyan.withValues(alpha: 0.12),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: _TypedPaginatedFeed(api: widget.api, total: total),
              );
            },
          ),
          const SizedBox(height: 12),
          const _WatchHint(
            'Counted by items, not pages: Convex pages are reactive and can '
            'grow/shrink as data changes, so there is no fixed "page X of Y". '
            'Post a message — it appears atop the loaded list instantly and the '
            '"of N" total ticks up live.',
          ),
        ],
      ),
    );
  }
}

/// Reactive feed backed by the generated, typed `messages:paginatePublic`
/// binding. Owns a [TypedConvexPaginatedQuery] for its lifetime — created once
/// and cancelled on dispose — and renders its page items as the typed
/// `PaginatePublicPageItem` record (note `item.author` / `item.text`, not
/// untyped map lookups).
class _TypedPaginatedFeed extends StatefulWidget {
  const _TypedPaginatedFeed({required this.api, required this.total});

  final ConvexApi api;
  final int total;

  @override
  State<_TypedPaginatedFeed> createState() => _TypedPaginatedFeedState();
}

class _TypedPaginatedFeedState extends State<_TypedPaginatedFeed> {
  // The element type (PaginatePublicPageItem) is inferred from the typed API.
  late final _query = widget.api.messages.paginatePublic(pageSize: 10);

  @override
  void dispose() {
    _query.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: _query.stream,
      initialData: _query.current,
      builder: (context, snapshot) {
        final result = snapshot.data!;
        final items = result.items;
        final status = result.status;

        if (status == ConvexPaginationStatus.loadingFirstPage) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        if (status == ConvexPaginationStatus.error) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Failed to load — is messages:paginatePublic deployed?',
                textAlign: TextAlign.center,
                style: TextStyle(color: ConciergeColors.danger),
              ),
            ),
          );
        }
        if (items.isEmpty) {
          return const Center(
            child: Text(
              'Empty feed — tap "Seed demo feed".',
              style: TextStyle(color: ConciergeColors.textDim),
            ),
          );
        }
        return Column(
          children: <Widget>[
            _PaginationProgress(
              loaded: items.length,
              total: widget.total,
              exhausted: status == ConvexPaginationStatus.exhausted,
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: items.length + 1,
                itemBuilder: (context, index) {
                  if (index < items.length) {
                    final item = items[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: <Widget>[
                          Text(
                            '${index + 1}'.padLeft(2, '0'),
                            style: const TextStyle(
                              color: ConciergeColors.textDim,
                              fontFeatures: <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '${item.author}: ${item.text}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Center(
                      child: switch (status) {
                        ConvexPaginationStatus.exhausted => const Text(
                          '— end of feed —',
                          style: TextStyle(color: ConciergeColors.textDim),
                        ),
                        ConvexPaginationStatus.loadingMore =>
                          const CircularProgressIndicator(strokeWidth: 2),
                        _ => OutlinedButton(
                          onPressed: () => _query.loadMore(),
                          child: const Text('Load more'),
                        ),
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Item-based progress for the cursor pagination. Convex pagination is
/// cursor-based with reactive, variable-size pages, so a "page X of Y" is not
/// meaningful; this shows the exact "N of TOTAL" items instead (TOTAL comes from
/// the companion `messages:countPublic` query).
class _PaginationProgress extends StatelessWidget {
  const _PaginationProgress({
    required this.loaded,
    required this.total,
    required this.exhausted,
  });

  final int loaded;
  final int total;
  final bool exhausted;

  @override
  Widget build(BuildContext context) {
    final known = total > 0;
    final shown = known ? (loaded > total ? total : loaded) : loaded;
    final fraction = known ? (loaded / total).clamp(0.0, 1.0) : null;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: ConciergeColors.cyan.withValues(alpha: 0.12),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                known ? 'Showing $shown of $total' : 'Showing $loaded',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: ConciergeColors.text,
                ),
              ),
              Text(
                exhausted ? 'all loaded' : 'more available',
                style: TextStyle(
                  color: exhausted
                      ? ConciergeColors.success
                      : ConciergeColors.cyanSoft,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 6,
              backgroundColor: ConciergeColors.surfaceHigh,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Rich connection status
// ---------------------------------------------------------------------------

class _ConnectionStatusDemoCard extends StatelessWidget {
  const _ConnectionStatusDemoCard();

  @override
  Widget build(BuildContext context) {
    final client = ConvexProvider.of(context);
    return SectionCard(
      eyebrow: 'RICH CONNECTION STATUS',
      title: 'Inflight, retries, and sync at a glance',
      subtitle:
          'ConvexConnectionStatusBuilder exposes the detailed status snapshot. '
          'Fire a request and watch the inflight counter climb; force a '
          'reconnect and watch retries and the loading flag move.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ConvexConnectionStatusBuilder(
            builder: (context, status) {
              return Column(
                children: <Widget>[
                  _StatusRow(
                    'WebSocket connected',
                    status.isWebSocketConnected,
                  ),
                  _StatusRow(
                    'Synced (connected + caught up)',
                    status.isConnected,
                  ),
                  _StatusRow('Loading (re-syncing)', status.isLoading),
                  _StatusRow('Has ever connected', status.hasEverConnected),
                  _StatusRow('Connection count', status.connectionCount),
                  _StatusRow('Reconnect retries', status.connectionRetries),
                  _StatusRow('Inflight mutations', status.inflightMutations),
                  _StatusRow('Inflight actions', status.inflightActions),
                  _StatusRow(
                    'Oldest inflight request',
                    status.timeOfOldestInflightRequest?.toLocal().toString() ??
                        '—',
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              FilledButton.icon(
                onPressed: () {
                  client.mutate('messages:sendPublic', <String, dynamic>{
                    'author': 'Showcase',
                    'text': 'Status probe ${TimeOfDay.now().format(context)}',
                  });
                },
                icon: const Icon(Icons.sync_alt_rounded),
                label: const Text('Fire a request'),
              ),
              OutlinedButton.icon(
                onPressed: () => client.reconnectNow('showcase-demo'),
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('Force reconnect'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const _WatchHint(
            'During a send, "Inflight mutations" ticks to 1 then back to 0. '
            'After "Force reconnect", retries / loading / connection count move.',
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow(this.label, this.value);

  final String label;
  final Object value;

  @override
  Widget build(BuildContext context) {
    final isBool = value is bool;
    final on = value == true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: ConciergeColors.textMuted),
            ),
          ),
          if (isBool)
            Icon(
              on ? Icons.check_circle_rounded : Icons.remove_circle_outline,
              size: 18,
              color: on ? ConciergeColors.success : ConciergeColors.textDim,
            )
          else
            Text(
              '$value',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3b. Reconnect / backoff config readout
// ---------------------------------------------------------------------------

/// A read-only readout of the live [ConvexClientConfig] backing reconnection,
/// backoff, and auth refresh. The values are the SDK defaults except where this
/// demo overrides them (the log level is raised to debug and a connectivity
/// signal is wired in); the config is threaded down from `app.dart` so the card
/// never drifts from the client that is actually running.
class _ConfigReadoutCard extends StatelessWidget {
  const _ConfigReadoutCard({required this.config});

  final ConvexClientConfig config;

  @override
  Widget build(BuildContext context) {
    final schedule = config.reconnectBackoff.isEmpty
        ? 'exponential (jittered)'
        : config.reconnectBackoff.map(_fmtDuration).join(', ');
    return SectionCard(
      eyebrow: 'RECONNECT & BACKOFF',
      title: 'The tunables behind reconnects',
      subtitle:
          'The live values driving reconnection, backoff, and auth refresh. '
          'All are SDK defaults except where this demo overrides them — the log '
          'level is raised to debug and a connectivity signal is wired in.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _StatusRow('Connect timeout', _fmtDuration(config.connectTimeout)),
          _StatusRow(
            'Inactivity timeout',
            _fmtDuration(config.inactivityTimeout),
          ),
          _StatusRow('Initial backoff', _fmtDuration(config.initialBackoff)),
          _StatusRow('Max backoff', _fmtDuration(config.maxBackoff)),
          _StatusRow(
            'Backoff jitter',
            '±${(config.backoffJitter * 100).round()}%',
          ),
          _StatusRow('Reconnect schedule', schedule),
          _StatusRow(
            'Refresh-token leeway',
            '${config.refreshTokenLeewaySeconds}s',
          ),
          _StatusRow('Log level', _logLevelLabel(config.logLevel)),
          _StatusRow('Connectivity signal', config.connectivitySignal != null),
          _StatusRow('Custom WS adapter', config.adapterFactory != null),
          const SizedBox(height: 12),
          const _WatchHint(
            'On network restore the connectivity signal reconnects the client '
            'immediately, cancelling any in-progress backoff (hard to trigger '
            'in-app without toggling the OS network). This card is read-only.',
          ),
        ],
      ),
    );
  }
}

/// Formats a [Duration] as whole seconds when it divides evenly, else as
/// milliseconds — enough for the config readout's small, round values.
String _fmtDuration(Duration d) =>
    d.inMilliseconds % 1000 == 0 ? '${d.inSeconds}s' : '${d.inMilliseconds}ms';

// ---------------------------------------------------------------------------
// 4. Auth refreshing
// ---------------------------------------------------------------------------

class _AuthRefreshingDemoCard extends StatelessWidget {
  const _AuthRefreshingDemoCard({this.onSimulateExpiredToken});

  /// When non-null (Demo auth mode), enables an on-demand trigger that hands the
  /// client an expired token to exercise the genuine reauth path. The badge
  /// itself stays passive — it tracks the real `authRefreshing` stream.
  final Future<void> Function()? onSimulateExpiredToken;

  @override
  Widget build(BuildContext context) {
    final onSimulate = onSimulateExpiredToken;
    return SectionCard(
      eyebrow: 'AUTH REFRESHING',
      title: 'A quiet "authenticating…" signal',
      subtitle:
          'ConvexAuthRefreshingBuilder reflects the real client signal: it '
          'lights up while a fresh token is fetched after the server rejects '
          'the current one, so you can show an indicator instead of a flicker.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ConvexAuthRefreshingBuilder(
            builder: (context, isRefreshing) {
              final color = isRefreshing
                  ? ConciergeColors.warning
                  : ConciergeColors.success;
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: color.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: <Widget>[
                    if (isRefreshing)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: ConciergeColors.warning,
                        ),
                      )
                    else
                      const Icon(
                        Icons.verified_user_rounded,
                        color: ConciergeColors.success,
                        size: 18,
                      ),
                    const SizedBox(width: 12),
                    Text(
                      isRefreshing ? 'Authenticating…' : 'Auth steady',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          if (onSimulate != null) ...<Widget>[
            const SizedBox(height: 14),
            ConvexAuthBuilder<DemoUserSession>(
              builder: (context, state) {
                final authed = state is AuthAuthenticated<DemoUserSession>;
                return OutlinedButton.icon(
                  onPressed: authed
                      ? () {
                          onSimulate();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Handed the client an expired token — watch '
                                'the badge reauthenticate.',
                              ),
                            ),
                          );
                        }
                      : null,
                  icon: const Icon(Icons.lock_reset_rounded),
                  label: Text(
                    authed
                        ? 'Force a token refresh'
                        : 'Sign in (Demo auth) to try this',
                  ),
                );
              },
            ),
          ],
          const SizedBox(height: 12),
          _WatchHint(
            onSimulate != null
                ? 'Tap "Force a token refresh" to hand the client a '
                      'deliberately expired token. The server rejects it, so '
                      'the client reauthenticates — the badge flips to '
                      '"Authenticating…" then back to "Auth steady", and your '
                      'session keeps working throughout.'
                : 'Genuine refreshes are triggered by the server rejecting an '
                      'expired token. Sign in with Demo auth to enable an '
                      'on-demand trigger here; this badge tracks the real '
                      'authRefreshing stream.',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 5. Structured logging
// ---------------------------------------------------------------------------

class _LoggingDemoCard extends StatefulWidget {
  const _LoggingDemoCard({required this.logsNotifier});

  final ValueNotifier<List<DartvexLogEvent>> logsNotifier;

  @override
  State<_LoggingDemoCard> createState() => _LoggingDemoCardState();
}

class _LoggingDemoCardState extends State<_LoggingDemoCard> {
  /// Active level filter; `null` shows every level.
  DartvexLogLevel? _filter;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      eyebrow: 'STRUCTURED LOGGING',
      title: 'Live SDK logs',
      subtitle:
          'DartvexLogger streams the SDK\'s structured transport, auth, and '
          'storage diagnostics. The client is wired at debug level; events land '
          'here newest-first, capped to the latest 150.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _LogLevelFilter(
            selected: _filter,
            onChanged: (level) => setState(() => _filter = level),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<List<DartvexLogEvent>>(
            valueListenable: widget.logsNotifier,
            builder: (context, events, _) {
              final visible = _filter == null
                  ? events
                  : events
                        .where((event) => event.level == _filter)
                        .toList(growable: false);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Text(
                        _filter == null
                            ? '${events.length} event(s)'
                            : '${visible.length} of ${events.length} event(s)',
                        style: const TextStyle(
                          color: ConciergeColors.textMuted,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: events.isEmpty
                            ? null
                            : () => widget.logsNotifier.value =
                                  const <DartvexLogEvent>[],
                        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                        label: const Text('Clear'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 320,
                    decoration: BoxDecoration(
                      color: ConciergeColors.surfaceLowest.withValues(
                        alpha: 0.6,
                      ),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: ConciergeColors.cyan.withValues(alpha: 0.12),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: visible.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                events.isEmpty
                                    ? 'No SDK logs yet — interact with the app '
                                          'to see transport, auth, and storage '
                                          'events stream in.'
                                    : 'No ${_logLevelLabel(_filter!)} events '
                                          'captured yet.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: ConciergeColors.textDim,
                                ),
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(12),
                            itemCount: visible.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) =>
                                _LogRow(event: visible[index]),
                          ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          const _WatchHint(
            'Interact with any tab (send a message, force a reconnect, sign in) '
            'and watch the transport/auth/storage events stream here in real '
            'time. Tokens and argument values are never logged — only metadata '
            'such as event reasons and argument keys.',
          ),
        ],
      ),
    );
  }
}

/// Compact level filter rendered as a row of choice chips. The leading "All"
/// chip clears the filter; the rest narrow the stream to a single level.
class _LogLevelFilter extends StatelessWidget {
  const _LogLevelFilter({required this.selected, required this.onChanged});

  final DartvexLogLevel? selected;
  final ValueChanged<DartvexLogLevel?> onChanged;

  @override
  Widget build(BuildContext context) {
    const options = <(String, DartvexLogLevel?)>[
      ('All', null),
      ('Debug', DartvexLogLevel.debug),
      ('Info', DartvexLogLevel.info),
      ('Warn', DartvexLogLevel.warn),
      ('Error', DartvexLogLevel.error),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final (label, level) in options)
          _LogFilterChip(
            label: label,
            color: level == null
                ? ConciergeColors.cyanSoft
                : _logLevelColor(level),
            selected: level == selected,
            onSelected: () => onChanged(level),
          ),
      ],
    );
  }
}

class _LogFilterChip extends StatelessWidget {
  const _LogFilterChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onSelected(),
      labelStyle: TextStyle(
        color: selected ? ConciergeColors.surfaceLowest : color,
        fontWeight: FontWeight.w700,
        fontSize: 12.5,
      ),
      selectedColor: color,
      backgroundColor: ConciergeColors.surfaceHigh,
      side: BorderSide(color: color.withValues(alpha: 0.4)),
    );
  }
}

/// A single structured log line: a level chip, the subsystem tag, the message,
/// and (when present) a compact `key=value` rendering of the structured data
/// payload and any associated error.
class _LogRow extends StatelessWidget {
  const _LogRow({required this.event});

  final DartvexLogEvent event;

  @override
  Widget build(BuildContext context) {
    final data = event.data;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _LogLevelChip(level: event.level),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (event.tag != null)
                Text(
                  event.tag!,
                  style: const TextStyle(
                    color: ConciergeColors.cyanSoft,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              Text(
                event.message,
                style: const TextStyle(
                  color: ConciergeColors.text,
                  fontSize: 12.5,
                  fontFamily: 'monospace',
                  height: 1.3,
                ),
              ),
              if (data != null && data.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    data.entries
                        .map((entry) => '${entry.key}=${entry.value}')
                        .join('  '),
                    style: const TextStyle(
                      color: ConciergeColors.textDim,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              if (event.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${event.error}',
                    style: const TextStyle(
                      color: ConciergeColors.danger,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LogLevelChip extends StatelessWidget {
  const _LogLevelChip({required this.level});

  final DartvexLogLevel level;

  @override
  Widget build(BuildContext context) {
    final color = _logLevelColor(level);
    return Container(
      width: 52,
      padding: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        _logLevelLabel(level).toUpperCase(),
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 10,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

Color _logLevelColor(DartvexLogLevel level) {
  return switch (level) {
    DartvexLogLevel.error => ConciergeColors.danger,
    DartvexLogLevel.warn => ConciergeColors.warning,
    DartvexLogLevel.info => ConciergeColors.cyanSoft,
    DartvexLogLevel.debug => ConciergeColors.textDim,
    DartvexLogLevel.off => ConciergeColors.textDim,
  };
}

String _logLevelLabel(DartvexLogLevel level) {
  return switch (level) {
    DartvexLogLevel.error => 'error',
    DartvexLogLevel.warn => 'warn',
    DartvexLogLevel.info => 'info',
    DartvexLogLevel.debug => 'debug',
    DartvexLogLevel.off => 'off',
  };
}

// ---------------------------------------------------------------------------

class _BackendRequiredNotice extends StatelessWidget {
  const _BackendRequiredNotice();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: ConciergeColors.warning.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: ConciergeColors.warning.withValues(alpha: 0.4),
            ),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.cloud_off_rounded, color: ConciergeColors.warning),
              SizedBox(height: 12),
              Text(
                'Set CONVEX_DEMO_URL to run the live feature demos.',
                textAlign: TextAlign.center,
                style: TextStyle(color: ConciergeColors.warning),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
