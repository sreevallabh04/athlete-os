import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../agent/coach_controller.dart';
import '../../data/ai_backend.dart';
import '../../tools/tool_args_validator.dart';
import '../../tools/tool_registry.dart';

/// Approve / Edit / Reject card for a pending write ("authorisation"), or
/// Allow / Not now for a consent request ("privacy check").
class PendingActionCard extends StatelessWidget {
  const PendingActionCard({
    super.key,
    required this.pending,
    required this.onApprove,
    required this.onReject,
  });

  final PendingAction pending;
  final void Function(Map<String, Object?>? editedArgs) onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    final consent = pending.isConsent;
    final accent = consent ? AppColors.warning : hud.accent;
    return Semantics(
      container: true,
      label: pending.title,
      child: Entrance(
        fromScale: 0.96,
        child: Padding(
          padding: const EdgeInsets.only(top: AppSpacing.lg),
          child: HudFrame(
            color: accent,
            cornerLength: 16,
            tag: consent ? 'PRIVACY·CHECK' : 'AUTH·REQUIRED',
            inset: -4,
            child: GlassPanel(
              accent: accent,
              glow: true,
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      GlowIcon(
                        consent
                            ? Icons.lock_outline_rounded
                            : Icons.verified_user_outlined,
                        color: accent,
                        size: 18,
                        framed: true,
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              consent
                                  ? 'PERMISSION REQUEST'
                                  : 'AWAITING YOUR APPROVAL',
                              style: hud.label(size: 11, color: accent),
                            ),
                            const SizedBox(height: 2),
                            Text(pending.title, style: t.titleMedium),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  for (final line in pending.summary)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 9, right: 10),
                            child: Container(
                              width: 5,
                              height: 1.5,
                              color: accent.withValues(alpha: 0.8),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              line,
                              style: t.bodyMedium?.copyWith(height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (!consent)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Nothing is saved until you approve.',
                        style: hud.mono(size: 10.5),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.lg),
                  Row(
                    children: [
                      Expanded(
                        child: HudButton(
                          label: consent ? 'Allow' : 'Approve',
                          icon: consent
                              ? Icons.lock_open_rounded
                              : Icons.check_rounded,
                          compact: true,
                          expand: true,
                          onPressed: () {
                            Haptics.success();
                            onApprove(null);
                          },
                        ),
                      ),
                      if (!consent) ...[
                        const SizedBox(width: AppSpacing.sm),
                        HudButton.secondary(
                          label: 'Edit',
                          icon: Icons.tune_rounded,
                          compact: true,
                          onPressed: () async {
                            final edited =
                                await showHudBottomSheet<Map<String, Object?>>(
                                  context,
                                  title: 'Edit · ${pending.title}',
                                  builder: (_) =>
                                      EditArgsDialog(pending: pending),
                                );
                            if (edited != null) {
                              Haptics.success();
                              onApprove(edited);
                            }
                          },
                        ),
                      ],
                      const SizedBox(width: AppSpacing.xs),
                      HudButton.ghost(
                        label: consent ? 'Not now' : 'Reject',
                        compact: true,
                        onPressed: () {
                          Haptics.heavy();
                          onReject();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A red "link fault" card with retry options.
class LinkFaultCard extends StatelessWidget {
  const LinkFaultCard({
    super.key,
    required this.error,
    this.onRetry,
    this.onFastRetry,
    this.onSettings,
  });

  final AiBackendException error;
  final VoidCallback? onRetry;

  /// "Try Groq": re-send on the fast provider.
  final VoidCallback? onFastRetry;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    final title = switch (error.code) {
      'timeout' => 'The link timed out',
      'network' => 'No connection to the AI core',
      'rate_limited' => 'Rate limited',
      'budget_exceeded' => 'Monthly budget reached',
      'unauthorized' => 'Session expired',
      'awaiting_credentials' => 'AI backend not configured',
      'providers_unavailable' => 'All providers are down',
      _ => 'The AI core reported a fault',
    };
    return Semantics(
      container: true,
      liveRegion: true,
      child: Entrance(
        child: Padding(
          padding: const EdgeInsets.only(top: AppSpacing.lg),
          child: GlassPanel(
            accent: AppColors.danger,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const GlowIcon(
                      Icons.report_gmailerrorred_rounded,
                      color: AppColors.danger,
                      size: 18,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      'LINK FAULT · ${error.code.toUpperCase()}',
                      style: hud.label(size: 11, color: AppColors.danger),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(title, style: t.titleSmall),
                const SizedBox(height: 2),
                Text(
                  error.message,
                  style: t.bodyMedium?.copyWith(color: hud.textMuted),
                ),
                if (onRetry != null ||
                    onFastRetry != null ||
                    onSettings != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      if (onRetry != null)
                        HudButton(
                          label: 'Retry',
                          icon: Icons.refresh_rounded,
                          compact: true,
                          onPressed: onRetry,
                        ),
                      if (onFastRetry != null)
                        HudButton.secondary(
                          label: 'Try Groq (fast)',
                          icon: Icons.bolt_rounded,
                          compact: true,
                          onPressed: onFastRetry,
                        ),
                      if (onSettings != null)
                        HudButton.secondary(
                          label: 'Settings',
                          icon: Icons.settings_outlined,
                          compact: true,
                          onPressed: onSettings,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Generic editor for tool arguments: one field per scalar leaf (including
/// leaves of objects inside arrays, e.g. items[0].calories). The result is
/// validated against the tool schema before it can be approved. Shown in a
/// HUD bottom sheet; pops the edited arguments.
class EditArgsDialog extends StatefulWidget {
  const EditArgsDialog({super.key, required this.pending});
  final PendingAction pending;

  @override
  State<EditArgsDialog> createState() => _EditArgsDialogState();
}

class _Leaf {
  _Leaf(this.path, this.label, this.original)
    : controller = TextEditingController(
        text: original is List ? original.join(', ') : '$original',
      );
  final List<Object> path;
  final String label;
  final Object? original;
  final TextEditingController controller;
}

class _EditArgsDialogState extends State<EditArgsDialog> {
  final _leaves = <_Leaf>[];
  List<String> _errors = const [];

  @override
  void initState() {
    super.initState();
    void walk(Object? v, List<Object> path, String label) {
      if (v is Map) {
        for (final e in v.entries) {
          walk(
            e.value,
            [...path, e.key as String],
            label.isEmpty
                ? _pretty(e.key as String)
                : '$label · ${_pretty(e.key as String)}',
          );
        }
      } else if (v is List && v.isNotEmpty && v.first is Map) {
        for (var i = 0; i < v.length; i++) {
          walk(v[i], [...path, i], '$label ${i + 1}');
        }
      } else if (v is String || v is num || v is bool || v is List) {
        _leaves.add(_Leaf(path, label, v));
      }
    }

    walk(widget.pending.args, const [], '');
  }

  @override
  void dispose() {
    for (final l in _leaves) {
      l.controller.dispose();
    }
    super.dispose();
  }

  static String _pretty(String key) => key.replaceAll('_', ' ');

  Map<String, Object?> _build() {
    Object? deepCopy(Object? v) => v is Map
        ? {for (final e in v.entries) e.key as String: deepCopy(e.value)}
        : v is List
        ? [for (final x in v) deepCopy(x)]
        : v;
    final out = deepCopy(widget.pending.args) as Map<String, Object?>;
    for (final l in _leaves) {
      final text = l.controller.text.trim();
      Object? value;
      final o = l.original;
      if (o is num) {
        value = num.tryParse(text) ?? text;
      } else if (o is bool) {
        value = text.toLowerCase() == 'true';
      } else if (o is List) {
        value = text.isEmpty
            ? <String>[]
            : text.split(',').map((s) => s.trim()).toList();
      } else {
        value = text;
      }
      Object? node = out;
      for (var i = 0; i < l.path.length - 1; i++) {
        final k = l.path[i];
        node = k is int ? (node as List)[k] : (node as Map)[k];
      }
      final last = l.path.last;
      if (last is int) {
        (node as List)[last] = value;
      } else {
        (node as Map)[last] = value;
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final l in _leaves)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: TextField(
                controller: l.controller,
                keyboardType: l.original is num
                    ? const TextInputType.numberWithOptions(decimal: true)
                    : TextInputType.text,
                decoration: InputDecoration(labelText: l.label),
              ),
            ),
          for (final e in _errors)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                e,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: AppColors.danger),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              HudButton.ghost(
                label: 'Cancel',
                onPressed: () => Navigator.pop(context),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: HudButton(
                  label: 'Approve edited',
                  icon: Icons.check_rounded,
                  expand: true,
                  onPressed: () {
                    final edited = _build();
                    final spec = toolByName(widget.pending.toolName);
                    final errors = spec == null
                        ? const <String>[]
                        : const ToolArgsValidator().validate(
                            spec.inputSchema,
                            edited,
                          );
                    if (errors.isNotEmpty) {
                      Haptics.warning();
                      setState(() => _errors = errors.take(4).toList());
                      return;
                    }
                    Navigator.pop(context, edited);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
