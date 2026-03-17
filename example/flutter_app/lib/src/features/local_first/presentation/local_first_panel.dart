import 'dart:async';

import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:dartvex_local/dartvex_local.dart';
import 'package:flutter/material.dart';

import '../../../../convex_api/modules/messages.dart' as messages_api;
import '../../../../convex_api/modules/tasks.dart' as tasks_api;
import '../../shared/presentation/conversation_widgets.dart';
import '../../shared/presentation/section_card.dart';
import '../data/local_first_support.dart';

class LocalFirstPanel extends StatefulWidget {
  const LocalFirstPanel({
    super.key,
    required this.client,
    required this.runtime,
    this.availabilityError,
  });

  final ConvexLocalClient? client;
  final ConvexRuntimeClient? runtime;
  final String? availabilityError;

  @override
  State<LocalFirstPanel> createState() => _LocalFirstPanelState();
}

class _LocalFirstPanelState extends State<LocalFirstPanel> {
  late final TextEditingController _authorController;
  late final TextEditingController _messageController;
  late final TextEditingController _taskTitleController;

  bool _chatBusy = false;
  bool _taskBusy = false;
  bool _clearingMessages = false;
  bool _clearingTasks = false;
  String? _chatStatus;
  String? _taskStatus;
  String? _controlStatus;

  @override
  void initState() {
    super.initState();
    _authorController = TextEditingController(text: 'Offline Explorer');
    _messageController = TextEditingController();
    _taskTitleController = TextEditingController();
  }

  @override
  void dispose() {
    _authorController.dispose();
    _messageController.dispose();
    _taskTitleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    final runtime = widget.runtime;
    if (client == null || runtime == null) {
      return SectionCard(
        eyebrow: 'LOCAL-FIRST',
        title: 'Offline Lab Unavailable',
        subtitle:
            'The local-first demo needs the local SQLite-backed store to boot successfully.',
        trailing: const ThreadPill(
          label: 'Unavailable',
          backgroundColor: Color(0xFFFFF1EF),
          foregroundColor: Color(0xFF8B4237),
          icon: Icons.error_outline,
        ),
        child: InlineNotice(
          message:
              widget.availabilityError ??
              'Set CONVEX_DEMO_URL and make sure the local SQLite runtime is available.',
          backgroundColor: const Color(0xFFFFF1EF),
          foregroundColor: const Color(0xFF8B4237),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1180;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildControlCard(context, client),
            const SizedBox(height: 16),
            if (isWide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: _buildChatCard(context, client, runtime)),
                  const SizedBox(width: 16),
                  Expanded(child: _buildTasksCard(context, client, runtime)),
                ],
              )
            else ...<Widget>[
              _buildChatCard(context, client, runtime),
              const SizedBox(height: 16),
              _buildTasksCard(context, client, runtime),
            ],
          ],
        );
      },
    );
  }

  Widget _buildControlCard(BuildContext context, ConvexLocalClient client) {
    return StreamBuilder<LocalNetworkMode>(
      stream: client.networkModeStream,
      initialData: client.currentNetworkMode,
      builder: (context, modeSnapshot) {
        return StreamBuilder<LocalConnectionState>(
          stream: client.connectionState,
          initialData: client.currentConnectionState,
          builder: (context, connectionSnapshot) {
            return StreamBuilder<List<PendingMutation>>(
              stream: client.pendingMutations,
              initialData: client.currentPendingMutations,
              builder: (context, pendingSnapshot) {
                final mode = modeSnapshot.data ?? LocalNetworkMode.auto;
                final connection =
                    connectionSnapshot.data ?? LocalConnectionState.online;
                final pending =
                    pendingSnapshot.data ?? const <PendingMutation>[];

                return SectionCard(
                  eyebrow: 'LOCAL-FIRST',
                  title: 'Offline Queue Lab',
                  subtitle:
                      'Freeze the local layer, keep writing against cached data, then resume sync and watch the queue replay.',
                  trailing: ThreadPill(
                    label: mode == LocalNetworkMode.offline
                        ? 'Forced offline'
                        : 'Auto sync',
                    backgroundColor: mode == LocalNetworkMode.offline
                        ? const Color(0xFF54340E)
                        : const Color(0xFF1E3A5C),
                    foregroundColor: mode == LocalNetworkMode.offline
                        ? const Color(0xFFF59E0B)
                        : const Color(0xFF3B82F6),
                    icon: mode == LocalNetworkMode.offline
                        ? Icons.wifi_off_rounded
                        : Icons.sync_rounded,
                  ),
                  backgroundColor: const Color(
                    0xFF1A1F2E,
                  ).withValues(alpha: 0.95),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: <Widget>[
                          _StateChip(
                            label: 'Connection ${connection.name}',
                            color: switch (connection) {
                              LocalConnectionState.online => const Color(
                                0xFF10B981,
                              ),
                              LocalConnectionState.syncing => const Color(
                                0xFF818CF8,
                              ),
                              LocalConnectionState.offline => const Color(
                                0xFFF59E0B,
                              ),
                            },
                          ),
                          _StateChip(
                            label:
                                '${pending.length} pending write${pending.length == 1 ? '' : 's'}',
                            color: pending.isEmpty
                                ? const Color(0xFF6B7280)
                                : const Color(0xFFEF4444),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: <Widget>[
                          FilledButton.icon(
                            onPressed: () async {
                              await client.setNetworkMode(
                                mode == LocalNetworkMode.offline
                                    ? LocalNetworkMode.auto
                                    : LocalNetworkMode.offline,
                              );
                              if (!mounted) {
                                return;
                              }
                              setState(() {
                                _controlStatus =
                                    mode == LocalNetworkMode.offline
                                    ? 'Sync resumed. Pending writes will replay now.'
                                    : 'Forced offline mode enabled for the local-first lab.';
                              });
                            },
                            icon: Icon(
                              mode == LocalNetworkMode.offline
                                  ? Icons.sync_rounded
                                  : Icons.wifi_off_rounded,
                            ),
                            label: Text(
                              mode == LocalNetworkMode.offline
                                  ? 'Resume sync'
                                  : 'Go offline',
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () async {
                              await client.clearCache();
                              if (!mounted) {
                                return;
                              }
                              setState(() {
                                _controlStatus = 'Local cache cleared.';
                              });
                            },
                            icon: const Icon(Icons.cleaning_services_outlined),
                            label: const Text('Clear cache'),
                          ),
                          OutlinedButton.icon(
                            onPressed: pending.isEmpty
                                ? null
                                : () async {
                                    await client.clearQueue();
                                    if (!mounted) {
                                      return;
                                    }
                                    setState(() {
                                      _controlStatus =
                                          'Pending mutation queue cleared.';
                                    });
                                  },
                            icon: const Icon(Icons.playlist_remove_rounded),
                            label: const Text('Clear queue'),
                          ),
                        ],
                      ),
                      if (_controlStatus != null) ...<Widget>[
                        const SizedBox(height: 14),
                        InlineNotice(message: _controlStatus!),
                      ],
                      if (pending.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 16),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0xFF252D3D),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  'Queued operations',
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 10),
                                for (final mutation in pending) ...<Widget>[
                                  Text(
                                    '${mutation.mutationName} (${mutation.status.name})',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  if (mutation != pending.last)
                                    const SizedBox(height: 8),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildChatCard(
    BuildContext context,
    ConvexLocalClient client,
    ConvexRuntimeClient runtime,
  ) {
    final currentAuthor = _authorController.text.trim();
    return SectionCard(
      eyebrow: 'PUBLIC CHAT',
      title: 'Local-first Messages',
      subtitle:
          'Load the public feed online, switch offline, post locally, then resume sync to replay the queued mutation.',
      trailing: const ThreadPill(
        label: 'Cache + queue',
        backgroundColor: Color(0xFFE4F4EF),
        foregroundColor: Color(0xFF0E635A),
        icon: Icons.chat_bubble_outline_rounded,
      ),
      backgroundColor: const Color(0xFF1A1F2E).withValues(alpha: 0.95),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ConvexQuery<List<messages_api.ListPublicResultItem>>(
            client: runtime,
            query: 'messages:listPublic',
            decode: decodeLocalPublicMessages,
            builder: (context, snapshot) {
              if (snapshot.isLoading) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return InlineNotice(
                  message: snapshot.error.toString(),
                  backgroundColor: const Color(0xFFFFF1EF),
                  foregroundColor: const Color(0xFF8B4237),
                );
              }

              final messages =
                  snapshot.data ?? const <messages_api.ListPublicResultItem>[];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      _StateChip(
                        label: 'Source ${snapshot.source.name}',
                        color: snapshot.source == ConvexQuerySource.cache
                            ? const Color(0xFFF59E0B)
                            : const Color(0xFF10B981),
                      ),
                      if (snapshot.hasPendingWrites)
                        const _StateChip(
                          label: 'Pending writes',
                          color: Color(0xFFEF4444),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 160),
                    child: messages.isEmpty
                        ? const EmptyThreadState(
                            title: 'Nothing cached yet',
                            body:
                                'Load the feed online once, or go offline and send a message to create a local-first trace.',
                            icon: Icons.mark_chat_unread_outlined,
                          )
                        : Column(
                            children: messages
                                .map(
                                  (message) => Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: ChatBubble(
                                      title: message.author,
                                      body: message.text,
                                      meta:
                                          'Updated ${formatMessageTimestamp(message.creationtime)}',
                                      alignEnd:
                                          currentAuthor.isNotEmpty &&
                                          message.author == currentAuthor,
                                      accentColor: const Color(0xFF10B981),
                                      neutralColor: const Color(0xFF2D3748),
                                    ),
                                  ),
                                )
                                .toList(growable: false),
                          ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _authorController,
            decoration: const InputDecoration(
              labelText: 'Author',
              hintText: 'Offline Explorer',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _messageController,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Message',
              hintText: 'Write something, then switch back online',
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Queued mutations stay visible through the cache-backed query.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFFA0A9B8),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _chatBusy || _clearingMessages ? null : () => _clearPublicMessages(client),
                style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF10B981)),
                icon: Icon(_clearingMessages ? Icons.hourglass_top : Icons.delete_sweep_rounded),
                label: Text(_clearingMessages ? 'Clearing...' : 'Clear'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _chatBusy ? null : () => _sendPublicMessage(client),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                ),
                icon: Icon(
                  _chatBusy ? Icons.hourglass_top : Icons.send_rounded,
                ),
                label: Text(_chatBusy ? 'Sending...' : 'Send'),
              ),
            ],
          ),
          if (_chatStatus != null) ...<Widget>[
            const SizedBox(height: 12),
            InlineNotice(message: _chatStatus!),
          ],
        ],
      ),
    );
  }

  Widget _buildTasksCard(
    BuildContext context,
    ConvexLocalClient client,
    ConvexRuntimeClient runtime,
  ) {
    return SectionCard(
      eyebrow: 'TASK BOARD',
      title: 'Local-first Tasks',
      subtitle:
          'Create or advance tasks offline, keep the board reactive from cache, and then replay to the server.',
      trailing: const ThreadPill(
        label: 'Optimistic lane moves',
        backgroundColor: Color(0xFFE8F3FF),
        foregroundColor: Color(0xFF155EEF),
        icon: Icons.task_alt_outlined,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ConvexQuery<List<tasks_api.ListBoardResultItem>>(
            client: runtime,
            query: 'tasks:listBoard',
            decode: decodeLocalTasks,
            builder: (context, snapshot) {
              if (snapshot.isLoading) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return InlineNotice(
                  message: snapshot.error.toString(),
                  backgroundColor: const Color(0xFFFFF1EF),
                  foregroundColor: const Color(0xFF8B4237),
                );
              }

              final tasks =
                  snapshot.data ?? const <tasks_api.ListBoardResultItem>[];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      _StateChip(
                        label: 'Source ${snapshot.source.name}',
                        color: snapshot.source == ConvexQuerySource.cache
                            ? const Color(0xFFF59E0B)
                            : const Color(0xFF3B82F6),
                      ),
                      if (snapshot.hasPendingWrites)
                        const _StateChip(
                          label: 'Pending writes',
                          color: Color(0xFFEF4444),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (tasks.isEmpty)
                    const EmptyThreadState(
                      title: 'No tasks yet',
                      body:
                          'Load the board once online or create a task while offline to see the cache grow.',
                      icon: Icons.dashboard_customize_outlined,
                    )
                  else
                    Column(
                      children: tasks
                          .take(6)
                          .map(
                            (task) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _TaskPreviewTile(
                                task: task,
                                busy: _taskBusy,
                                onAdvance: () => _advanceTask(client, task),
                              ),
                            ),
                          )
                          .toList(growable: false),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _taskTitleController,
            decoration: const InputDecoration(
              labelText: 'New task title',
              hintText: 'Ship local-first replay demo',
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Create locally now. The board is patched optimistically before replay.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFFA0A9B8),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _taskBusy || _clearingTasks ? null : () => _clearTasks(client),
                icon: Icon(_clearingTasks ? Icons.hourglass_top : Icons.delete_sweep_rounded),
                label: Text(_clearingTasks ? 'Clearing...' : 'Clear'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _taskBusy ? null : () => _createTask(client),
                icon: Icon(
                  _taskBusy ? Icons.hourglass_top : Icons.add_task_rounded,
                ),
                label: Text(_taskBusy ? 'Saving...' : 'Create'),
              ),
            ],
          ),
          if (_taskStatus != null) ...<Widget>[
            const SizedBox(height: 12),
            InlineNotice(message: _taskStatus!),
          ],
        ],
      ),
    );
  }

  Future<void> _sendPublicMessage(ConvexLocalClient client) async {
    final author = _authorController.text.trim();
    final text = _messageController.text.trim();
    if (author.isEmpty || text.isEmpty) {
      setState(() {
        _chatStatus = 'Author and message are both required.';
      });
      return;
    }

    setState(() {
      _chatBusy = true;
      _chatStatus = null;
    });
    try {
      final result = await client.mutate(
        'messages:sendPublic',
        <String, dynamic>{'author': author, 'text': text},
      );
      _messageController.clear();
      setState(() {
        _chatStatus = switch (result) {
          LocalMutationQueued() =>
            'Message queued locally. Resume sync to replay it.',
          LocalMutationSuccess() => 'Message sent to the server immediately.',
          LocalMutationFailed(:final error) => error.toString(),
        };
      });
    } catch (error) {
      setState(() {
        _chatStatus = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _chatBusy = false;
        });
      }
    }
  }

  Future<void> _createTask(ConvexLocalClient client) async {
    final title = _taskTitleController.text.trim();
    if (title.isEmpty) {
      setState(() {
        _taskStatus = 'Task title is required.';
      });
      return;
    }

    setState(() {
      _taskBusy = true;
      _taskStatus = null;
    });
    try {
      final result = await client.mutate('tasks:createTask', <String, dynamic>{
        'title': title,
        'summary': 'Created from the local-first demo tab.',
        'priority': 'medium',
        'estimatePoints': 3,
        'labels': <String>['demo', 'local-first'],
        'assignee': null,
        'dueAt': null,
      });
      _taskTitleController.clear();
      setState(() {
        _taskStatus = switch (result) {
          LocalMutationQueued() =>
            'Task created locally and queued for replay.',
          LocalMutationSuccess() => 'Task created on the server immediately.',
          LocalMutationFailed(:final error) => error.toString(),
        };
      });
    } catch (error) {
      setState(() {
        _taskStatus = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _taskBusy = false;
        });
      }
    }
  }

  Future<void> _advanceTask(
    ConvexLocalClient client,
    tasks_api.ListBoardResultItem task,
  ) async {
    setState(() {
      _taskBusy = true;
      _taskStatus = null;
    });
    try {
      final result = await client.mutate('tasks:advanceTask', <String, dynamic>{
        'taskId': task.id.value,
      });
      setState(() {
        _taskStatus = switch (result) {
          LocalMutationQueued() =>
            '${task.title} advanced locally and is waiting for replay.',
          LocalMutationSuccess() => '${task.title} advanced on the server.',
          LocalMutationFailed(:final error) => error.toString(),
        };
      });
    } catch (error) {
      setState(() {
        _taskStatus = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _taskBusy = false;
        });
      }
    }
  }

  Future<void> _clearPublicMessages(ConvexLocalClient client) async {
    setState(() {
      _clearingMessages = true;
      _chatStatus = null;
    });
    try {
      final result = await client.mutate('messages:clearPublicMessages', const <String, dynamic>{});
      setState(() {
        _chatStatus = switch (result) {
          LocalMutationQueued() => 'Clear queued for replay.',
          LocalMutationSuccess() => 'Messages cleared on server.',
          LocalMutationFailed(:final error) => error.toString(),
        };
      });
    } catch (error) {
      setState(() {
        _chatStatus = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _clearingMessages = false;
        });
      }
    }
  }

  Future<void> _clearTasks(ConvexLocalClient client) async {
    setState(() {
      _clearingTasks = true;
      _taskStatus = null;
    });
    try {
      final result = await client.mutate('tasks:clearTasks', const <String, dynamic>{});
      setState(() {
        _taskStatus = switch (result) {
          LocalMutationQueued() => 'Clear queued for replay.',
          LocalMutationSuccess() => 'Tasks cleared on server.',
          LocalMutationFailed(:final error) => error.toString(),
        };
      });
    } catch (error) {
      setState(() {
        _taskStatus = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _clearingTasks = false;
        });
      }
    }
  }
}

class _TaskPreviewTile extends StatelessWidget {
  const _TaskPreviewTile({
    required this.task,
    required this.busy,
    required this.onAdvance,
  });

  final tasks_api.ListBoardResultItem task;
  final bool busy;
  final VoidCallback onAdvance;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF252D3D),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF2D3748)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    task.title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _StateChip(
                  label: task.status.replaceAll('_', ' '),
                  color: switch (task.status) {
                    'done' => const Color(0xFF3B82F6),
                    'in_progress' => const Color(0xFF10B981),
                    _ => const Color(0xFF8B5CF6),
                  },
                ),
              ],
            ),
            if (task.summary != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                task.summary!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: const Color(0xFFA0A9B8)),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${task.priority} priority • ${task.labels.join(', ')}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFFA0A9B8),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: busy ? null : onAdvance,
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: const Text('Advance'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}
