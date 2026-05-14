import 'package:flutter/material.dart';

import '../../../../convex_api/api.dart';
import '../../../../convex_api/modules/demo.dart' as demo_api;
import '../../shared/presentation/conversation_widgets.dart';
import '../../shared/presentation/concierge_design.dart';
import '../../shared/presentation/section_card.dart';

class ActionPanel extends StatefulWidget {
  const ActionPanel({super.key, required this.api});

  final ConvexApi? api;

  @override
  State<ActionPanel> createState() => _ActionPanelState();
}

class _ActionPanelState extends State<ActionPanel> {
  late final TextEditingController _messageController;
  bool _isRunning = false;
  demo_api.PingActionResult? _lastResult;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    _messageController = TextEditingController(
      text: 'Ping from the Convex Flutter demo',
    );
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _runAction() async {
    final api = widget.api;
    if (api == null) {
      return;
    }

    setState(() {
      _isRunning = true;
      _lastError = null;
    });

    try {
      final result = await api.demo.pingAction(
        message: _messageController.text.trim(),
      );
      setState(() {
        _lastResult = result;
      });
    } catch (error) {
      setState(() {
        _lastError = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isRunning = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      eyebrow: 'ACTION FLOW',
      title: 'Action Roundtrip',
      subtitle:
          'This action goes through the generated API and reports whether the '
          'server saw the current request as authenticated.',
      trailing: const ThreadPill(
        label: 'Server action',
        backgroundColor: Color(0x1AB6C4FF),
        foregroundColor: ConciergeColors.secondary,
        icon: Icons.bolt_outlined,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: _messageController,
            minLines: 2,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Action payload'),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: widget.api == null || _isRunning ? null : _runAction,
              style: FilledButton.styleFrom(
                backgroundColor: ConciergeColors.secondary,
                foregroundColor: ConciergeColors.surfaceLowest,
              ),
              icon: Icon(
                _isRunning ? Icons.hourglass_top : Icons.play_arrow_rounded,
              ),
              label: Text(_isRunning ? 'Running...' : 'Run Action'),
            ),
          ),
          const SizedBox(height: 14),
          if (_lastError != null)
            InlineNotice(
              message: _lastError!,
              backgroundColor: ConciergeColors.danger.withValues(alpha: 0.14),
              foregroundColor: ConciergeColors.danger,
            )
          else if (_lastResult != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: ConciergeColors.secondary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: ConciergeColors.secondary.withValues(alpha: 0.20),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Action response',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: ConciergeColors.secondary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('echoedText: ${_lastResult!.echoedText}'),
                  const SizedBox(height: 6),
                  Text('isAuthenticated: ${_lastResult!.isAuthenticated}'),
                  const SizedBox(height: 6),
                  Text('viewerName: ${_lastResult!.viewerName ?? 'none'}'),
                ],
              ),
            )
          else
            const InlineNotice(
              message: 'Run the action to inspect the typed response.',
            ),
        ],
      ),
    );
  }
}
