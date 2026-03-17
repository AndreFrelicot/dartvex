import 'package:flutter/material.dart';

import '../../../../convex_api/api.dart';
import '../../../../convex_api/modules/tasks.dart' as tasks_api;
import '../../shared/presentation/conversation_widgets.dart';
import '../../shared/presentation/generated_subscription_builder.dart';
import '../../shared/presentation/section_card.dart';

class TasksBoardPanel extends StatefulWidget {
  const TasksBoardPanel({super.key, required this.api});

  final ConvexApi? api;

  @override
  State<TasksBoardPanel> createState() => _TasksBoardPanelState();
}

class _TasksBoardPanelState extends State<TasksBoardPanel> {
  static const List<_TaskLaneSpec> _lanes = <_TaskLaneSpec>[
    _TaskLaneSpec(
      status: 'backlog',
      label: 'Backlog',
      accentColor: Color(0xFF7C3AED),
      icon: Icons.inbox_outlined,
    ),
    _TaskLaneSpec(
      status: 'in_progress',
      label: 'In progress',
      accentColor: Color(0xFF0F766E),
      icon: Icons.timelapse_rounded,
    ),
    _TaskLaneSpec(
      status: 'done',
      label: 'Done',
      accentColor: Color(0xFF2563EB),
      icon: Icons.task_alt_rounded,
    ),
  ];

  late final TextEditingController _titleController;
  late final TextEditingController _summaryController;
  late final TextEditingController _assigneeController;
  late final TextEditingController _labelsController;

  bool _isCreating = false;
  bool _isSeeding = false;
  bool _isClearing = false;
  bool _showAdvancedFields = false;
  String? _statusMessage;
  String _priority = 'medium';
  String _selectedStatus = 'backlog';
  double _estimatePoints = 3;
  _DuePreset _duePreset = _DuePreset.none;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _summaryController = TextEditingController();
    _assigneeController = TextEditingController();
    _labelsController = TextEditingController(text: 'sdk, flutter');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _summaryController.dispose();
    _assigneeController.dispose();
    _labelsController.dispose();
    super.dispose();
  }

  Future<void> _createTask() async {
    final api = widget.api;
    if (api == null) {
      return;
    }

    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() {
        _statusMessage = 'Task title is required.';
      });
      return;
    }

    setState(() {
      _isCreating = true;
      _statusMessage = null;
    });

    try {
      await api.tasks.createtask(
        assignee: _nullIfEmpty(_assigneeController.text),
        dueat: _duePreset.toDueAt(),
        estimatepoints: _estimatePoints,
        labels: _parseLabels(_labelsController.text),
        priority: _priority,
        summary: _nullIfEmpty(_summaryController.text),
        title: title,
      );
      _titleController.clear();
      _summaryController.clear();
      setState(() {
        _statusMessage = 'Task created in backlog.';
      });
    } catch (error) {
      setState(() {
        _statusMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isCreating = false;
        });
      }
    }
  }

  Future<void> _seedBoard() async {
    final api = widget.api;
    if (api == null) {
      return;
    }

    setState(() {
      _isSeeding = true;
      _statusMessage = null;
    });

    try {
      final inserted = await api.tasks.seedboard();
      setState(() {
        _statusMessage = inserted == 0
            ? 'Sample tasks already exist.'
            : 'Added ${inserted.toInt()} sample tasks.';
      });
    } catch (error) {
      setState(() {
        _statusMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSeeding = false;
        });
      }
    }
  }

  Future<void> _clearBoard() async {
    final api = widget.api;
    if (api == null) return;

    setState(() {
      _isClearing = true;
      _statusMessage = null;
    });
    try {
      final count = await api.tasks.clearboard();
      setState(() {
        _statusMessage = '${count.toInt()} task${count.toInt() == 1 ? '' : 's'} cleared.';
      });
    } catch (error) {
      setState(() {
        _statusMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isClearing = false;
        });
      }
    }
  }

  Future<void> _advanceTask(tasks_api.ListBoardResultItem task) async {
    final api = widget.api;
    if (api == null) {
      return;
    }

    try {
      final result = await api.tasks.advancetask(taskid: task.id);
      setState(() {
        _selectedStatus = result.status;
        _statusMessage =
            '${task.title} moved to ${_statusLabel(result.status)}.';
      });
    } catch (error) {
      setState(() {
        _statusMessage = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 980;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SectionCard(
              eyebrow: 'RICH TYPES',
              title: 'Tasks Board',
              subtitle:
                  'Generated bindings over ids, nullable fields, arrays, enums, '
                  'and realtime lane updates.',
              trailing: Wrap(
                spacing: 8,
                children: <Widget>[
                  OutlinedButton.icon(
                    onPressed: widget.api == null || _isClearing ? null : _clearBoard,
                    icon: Icon(_isClearing ? Icons.hourglass_top : Icons.delete_sweep_rounded),
                    label: Text(_isClearing ? 'Clearing...' : 'Clear board'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: widget.api == null || _isSeeding ? null : _seedBoard,
                    icon: Icon(
                      _isSeeding ? Icons.hourglass_top : Icons.auto_awesome,
                    ),
                    label: Text(
                      _isSeeding ? 'Adding samples...' : 'Add sample tasks',
                    ),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const InlineNotice(
                    message:
                        'Add sample tasks inserts a ready-made board so you can '
                        'test lane moves, labels, due dates, and generated types immediately.',
                  ),
                  const SizedBox(height: 12),
                  if (widget.api == null)
                    const InlineNotice(
                      message:
                          'Set CONVEX_DEMO_URL to load the live typed project board.',
                    )
                  else
                    GeneratedSubscriptionBuilder<
                      List<tasks_api.ListBoardResultItem>
                    >(
                      subscriptionKey: widget.api!,
                      subscribe: widget.api!.tasks.listboardSubscribe,
                      builder: (context, snapshot) {
                        if (snapshot.isLoading) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                              ),
                            ),
                          );
                        }
                        if (snapshot.hasError) {
                          return InlineNotice(
                            message: snapshot.error!,
                            backgroundColor: const Color(0xFFFFF1EF),
                            foregroundColor: const Color(0xFF8B4237),
                          );
                        }

                        final tasks =
                            snapshot.data ??
                            const <tasks_api.ListBoardResultItem>[];

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            _TaskSummaryStrip(tasks: tasks),
                            const SizedBox(height: 16),
                            if (tasks.isEmpty)
                              const EmptyThreadState(
                                title: 'No tasks yet',
                                body:
                                    'Add sample tasks or create a task below to '
                                    'exercise richer generated data than chat.',
                                icon: Icons.dashboard_customize_outlined,
                              )
                            else if (isWide)
                              _WideBoard(
                                lanes: _lanes,
                                tasks: tasks,
                                onAdvanceTask: _advanceTask,
                              )
                            else
                              _CompactBoard(
                                lanes: _lanes,
                                selectedStatus: _selectedStatus,
                                tasks: tasks,
                                onStatusSelected: (status) {
                                  setState(() {
                                    _selectedStatus = status;
                                  });
                                },
                                onAdvanceTask: _advanceTask,
                              ),
                          ],
                        );
                      },
                    ),
                  if (_statusMessage != null) ...<Widget>[
                    const SizedBox(height: 14),
                    InlineNotice(message: _statusMessage!),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Create task',
              subtitle:
                  'Use one typed mutation with optional assignee, due date, labels, '
                  'and estimates.',
              child: _TaskComposer(
                titleController: _titleController,
                summaryController: _summaryController,
                assigneeController: _assigneeController,
                labelsController: _labelsController,
                priority: _priority,
                estimatePoints: _estimatePoints,
                duePreset: _duePreset,
                showAdvancedFields: _showAdvancedFields,
                isCreating: _isCreating,
                onToggleAdvanced: () {
                  setState(() {
                    _showAdvancedFields = !_showAdvancedFields;
                  });
                },
                onPriorityChanged: (value) {
                  setState(() {
                    _priority = value;
                  });
                },
                onEstimateChanged: (value) {
                  setState(() {
                    _estimatePoints = value;
                  });
                },
                onDuePresetChanged: (value) {
                  setState(() {
                    _duePreset = value;
                  });
                },
                onCreateTask: widget.api == null || _isCreating
                    ? null
                    : _createTask,
              ),
            ),
          ],
        );
      },
    );
  }

  List<String> _parseLabels(String raw) {
    return raw
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();
  }

  String? _nullIfEmpty(String raw) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class _TaskSummaryStrip extends StatelessWidget {
  const _TaskSummaryStrip({required this.tasks});

  final List<tasks_api.ListBoardResultItem> tasks;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dueSoon = tasks
        .where(
          (task) =>
              task.dueat != null &&
              DateTime.fromMillisecondsSinceEpoch(
                task.dueat!.toInt(),
              ).isBefore(now.add(const Duration(days: 4))),
        )
        .length;

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        _SummaryPill(label: 'Total', value: '${tasks.length}'),
        _SummaryPill(
          label: 'Backlog',
          value: '${_countByStatus(tasks, 'backlog')}',
        ),
        _SummaryPill(
          label: 'In progress',
          value: '${_countByStatus(tasks, 'in_progress')}',
        ),
        _SummaryPill(label: 'Done', value: '${_countByStatus(tasks, 'done')}'),
        _SummaryPill(label: 'Due soon', value: '$dueSoon'),
      ],
    );
  }

  int _countByStatus(List<tasks_api.ListBoardResultItem> tasks, String status) {
    return tasks.where((task) => task.status == status).length;
  }
}

class _SummaryPill extends StatelessWidget {
  const _SummaryPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF1F2937),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFFA0A9B8),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              value,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: const Color(0xFFF3F4F6),
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactBoard extends StatelessWidget {
  const _CompactBoard({
    required this.lanes,
    required this.selectedStatus,
    required this.tasks,
    required this.onStatusSelected,
    required this.onAdvanceTask,
  });

  final List<_TaskLaneSpec> lanes;
  final String selectedStatus;
  final List<tasks_api.ListBoardResultItem> tasks;
  final ValueChanged<String> onStatusSelected;
  final Future<void> Function(tasks_api.ListBoardResultItem task) onAdvanceTask;

  @override
  Widget build(BuildContext context) {
    final lane = lanes.firstWhere((item) => item.status == selectedStatus);
    final laneTasks = tasks
        .where((task) => task.status == selectedStatus)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SegmentedButton<String>(
          segments: lanes
              .map(
                (lane) => ButtonSegment<String>(
                  value: lane.status,
                  label: Text(lane.label),
                  icon: Icon(lane.icon, size: 18),
                ),
              )
              .toList(),
          selected: <String>{selectedStatus},
          onSelectionChanged: (selection) {
            if (selection.isNotEmpty) {
              onStatusSelected(selection.first);
            }
          },
        ),
        const SizedBox(height: 12),
        _LaneSection(
          lane: lane,
          tasks: laneTasks,
          onAdvanceTask: onAdvanceTask,
        ),
      ],
    );
  }
}

class _WideBoard extends StatelessWidget {
  const _WideBoard({
    required this.lanes,
    required this.tasks,
    required this.onAdvanceTask,
  });

  final List<_TaskLaneSpec> lanes;
  final List<tasks_api.ListBoardResultItem> tasks;
  final Future<void> Function(tasks_api.ListBoardResultItem task) onAdvanceTask;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (var index = 0; index < lanes.length; index++) ...<Widget>[
          Expanded(
            child: _LaneSection(
              lane: lanes[index],
              tasks: tasks
                  .where((task) => task.status == lanes[index].status)
                  .toList(),
              onAdvanceTask: onAdvanceTask,
            ),
          ),
          if (index != lanes.length - 1) const SizedBox(width: 12),
        ],
      ],
    );
  }
}

class _LaneSection extends StatelessWidget {
  const _LaneSection({
    required this.lane,
    required this.tasks,
    required this.onAdvanceTask,
  });

  final _TaskLaneSpec lane;
  final List<tasks_api.ListBoardResultItem> tasks;
  final Future<void> Function(tasks_api.ListBoardResultItem task) onAdvanceTask;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: lane.accentColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: lane.accentColor.withValues(alpha: 0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(lane.icon, color: lane.accentColor, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  lane.label,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: lane.accentColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              ThreadPill(
                label: '${tasks.length}',
                backgroundColor: lane.accentColor.withValues(alpha: 0.12),
                foregroundColor: lane.accentColor,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (tasks.isEmpty)
            EmptyThreadState(
              title: 'Nothing here',
              body: 'Move a task into ${lane.label.toLowerCase()}.',
              icon: lane.icon,
            )
          else
            Column(
              children: tasks
                  .map(
                    (task) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _TaskCard(
                        task: task,
                        lane: lane,
                        onAdvance: task.status == 'done'
                            ? null
                            : () => onAdvanceTask(task),
                      ),
                    ),
                  )
                  .toList(),
            ),
        ],
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.lane,
    required this.onAdvance,
  });

  final tasks_api.ListBoardResultItem task;
  final _TaskLaneSpec lane;
  final VoidCallback? onAdvance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1F2E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF2D3748)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Text(
                    task.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _PriorityChip(priority: task.priority),
              ],
            ),
            if (task.summary != null && task.summary!.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                task.summary!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFFA0A9B8),
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _MetaBadge(
                  icon: Icons.scatter_plot_outlined,
                  label: '${task.estimatepoints.toStringAsFixed(0)} pts',
                ),
                if (task.assignee != null)
                  _MetaBadge(
                    icon: Icons.person_outline_rounded,
                    label: task.assignee!,
                  ),
                if (task.dueat != null)
                  _MetaBadge(
                    icon: Icons.event_outlined,
                    label: _formatDueDate(task.dueat!),
                  ),
              ],
            ),
            if (task.labels.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: task.labels
                    .map(
                      (label) => DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xFF252D3D),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Text(
                            '#$label',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: const Color(0xFFA0A9B8),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Text(
                  _compactTaskId(task.id.value),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (onAdvance == null)
                  ThreadPill(
                    label: 'Done',
                    backgroundColor: lane.accentColor.withValues(alpha: 0.12),
                    foregroundColor: lane.accentColor,
                    icon: Icons.check_rounded,
                  )
                else
                  FilledButton.tonalIcon(
                    onPressed: onAdvance,
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                    label: Text(_nextActionLabel(task.status)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PriorityChip extends StatelessWidget {
  const _PriorityChip({required this.priority});

  final String priority;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (priority) {
      'high' => ('High', const Color(0xFFB91C1C)),
      'medium' => ('Medium', const Color(0xFFB45309)),
      _ => ('Low', const Color(0xFF2563EB)),
    };

    return ThreadPill(
      label: label,
      backgroundColor: color.withValues(alpha: 0.12),
      foregroundColor: color,
    );
  }
}

class _MetaBadge extends StatelessWidget {
  const _MetaBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF252D3D),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF2D3748)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 14, color: const Color(0xFFA0A9B8)),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: const Color(0xFFF3F4F6),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskComposer extends StatelessWidget {
  const _TaskComposer({
    required this.titleController,
    required this.summaryController,
    required this.assigneeController,
    required this.labelsController,
    required this.priority,
    required this.estimatePoints,
    required this.duePreset,
    required this.showAdvancedFields,
    required this.isCreating,
    required this.onToggleAdvanced,
    required this.onPriorityChanged,
    required this.onEstimateChanged,
    required this.onDuePresetChanged,
    required this.onCreateTask,
  });

  final TextEditingController titleController;
  final TextEditingController summaryController;
  final TextEditingController assigneeController;
  final TextEditingController labelsController;
  final String priority;
  final double estimatePoints;
  final _DuePreset duePreset;
  final bool showAdvancedFields;
  final bool isCreating;
  final VoidCallback onToggleAdvanced;
  final ValueChanged<String> onPriorityChanged;
  final ValueChanged<double> onEstimateChanged;
  final ValueChanged<_DuePreset> onDuePresetChanged;
  final Future<void> Function()? onCreateTask;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 720;
        final summaryField = TextField(
          controller: summaryController,
          minLines: 2,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Summary',
            hintText: 'What is this task about?',
          ),
        );

        final assigneeField = TextField(
          controller: assigneeController,
          decoration: const InputDecoration(
            labelText: 'Assignee',
            hintText: 'Optional owner',
          ),
        );

        final priorityField = DropdownButtonFormField<String>(
          initialValue: priority,
          decoration: const InputDecoration(labelText: 'Priority'),
          items: const <DropdownMenuItem<String>>[
            DropdownMenuItem(value: 'low', child: Text('Low')),
            DropdownMenuItem(value: 'medium', child: Text('Medium')),
            DropdownMenuItem(value: 'high', child: Text('High')),
          ],
          onChanged: (value) {
            if (value != null) {
              onPriorityChanged(value);
            }
          },
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: titleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'Ship typed local-first exploration',
              ),
            ),
            const SizedBox(height: 12),
            summaryField,
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onToggleAdvanced,
                icon: Icon(
                  showAdvancedFields
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
                label: Text(
                  showAdvancedFields
                      ? 'Hide advanced fields'
                      : 'Show advanced fields',
                ),
              ),
            ),
            if (showAdvancedFields) ...<Widget>[
              const SizedBox(height: 8),
              if (isWide)
                Row(
                  children: <Widget>[
                    Expanded(child: assigneeField),
                    const SizedBox(width: 12),
                    Expanded(child: priorityField),
                  ],
                )
              else ...<Widget>[
                assigneeField,
                const SizedBox(height: 12),
                priorityField,
              ],
              const SizedBox(height: 12),
              TextField(
                controller: labelsController,
                decoration: const InputDecoration(
                  labelText: 'Labels',
                  hintText: 'Comma separated labels',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Estimate',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              Slider(
                value: estimatePoints,
                min: 1,
                max: 8,
                divisions: 7,
                label: estimatePoints.toStringAsFixed(0),
                onChanged: onEstimateChanged,
              ),
              const SizedBox(height: 8),
              Text(
                'Due date preset',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _DuePreset.values
                    .map(
                      (preset) => ChoiceChip(
                        label: Text(preset.label),
                        selected: duePreset == preset,
                        onSelected: (_) => onDuePresetChanged(preset),
                      ),
                    )
                    .toList(),
              ),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: onCreateTask == null
                    ? null
                    : () {
                        onCreateTask!();
                      },
                icon: Icon(
                  isCreating ? Icons.hourglass_top : Icons.add_task_rounded,
                ),
                label: Text(isCreating ? 'Creating...' : 'Create task'),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TaskLaneSpec {
  const _TaskLaneSpec({
    required this.status,
    required this.label,
    required this.accentColor,
    required this.icon,
  });

  final String status;
  final String label;
  final Color accentColor;
  final IconData icon;
}

enum _DuePreset {
  none('No due date'),
  today('Today'),
  thisWeek('This week'),
  nextWeek('Next week');

  const _DuePreset(this.label);

  final String label;

  double? toDueAt() {
    final now = DateTime.now();
    final dueDate = switch (this) {
      _DuePreset.none => null,
      _DuePreset.today => DateTime(now.year, now.month, now.day, 18),
      _DuePreset.thisWeek => now.add(const Duration(days: 3)),
      _DuePreset.nextWeek => now.add(const Duration(days: 7)),
    };
    return dueDate?.millisecondsSinceEpoch.toDouble();
  }
}

String _formatDueDate(double dueAt) {
  final date = DateTime.fromMillisecondsSinceEpoch(dueAt.toInt()).toLocal();
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  return '$day/$month';
}

String _compactTaskId(String id) {
  if (id.length <= 14) {
    return id;
  }
  return '${id.substring(0, 6)}…${id.substring(id.length - 4)}';
}

String _nextActionLabel(String status) {
  return switch (status) {
    'backlog' => 'Start',
    'in_progress' => 'Complete',
    _ => 'Done',
  };
}

String _statusLabel(String status) {
  return switch (status) {
    'backlog' => 'Backlog',
    'in_progress' => 'In progress',
    'done' => 'Done',
    _ => status,
  };
}
