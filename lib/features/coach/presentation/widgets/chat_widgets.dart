import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../agent/coach_controller.dart';
import '../../tools/tool_args_validator.dart';
import '../../tools/tool_registry.dart';
import 'markdown_lite.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble.user(this.text, {super.key})
    : isUser = true,
      sources = const [];
  const MessageBubble.assistant(this.text, {super.key, this.sources = const []})
    : isUser = false;

  final String text;
  final bool isUser;
  final List<String> sources;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.84;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        gradient: isUser ? AppGradients.brand : null,
        color: isUser ? null : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(AppRadii.lg),
          topRight: const Radius.circular(AppRadii.lg),
          bottomLeft: Radius.circular(isUser ? AppRadii.lg : 6),
          bottomRight: Radius.circular(isUser ? 6 : AppRadii.lg),
        ),
      ),
      child: isUser
          ? Text(text, style: t.bodyLarge?.copyWith(color: Colors.white))
          : MarkdownLite(text, style: t.bodyLarge),
    );
    return Semantics(
      label: isUser ? 'You said' : 'Coach said',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Column(
          crossAxisAlignment: isUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            bubble,
            if (sources.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 6),
                child: Text(
                  'Sources: ${sources.join(' · ')}',
                  style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ToolActivityChip extends StatelessWidget {
  const ToolActivityChip(this.entry, {super.key});
  final ToolChipEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (entry.status) {
      ToolChipStatus.running => (Icons.sync, AppColors.info),
      ToolChipStatus.ok => (
        entry.isWrite ? Icons.check_circle_outline : Icons.dataset_outlined,
        entry.isWrite ? AppColors.success : scheme.onSurfaceVariant,
      ),
      ToolChipStatus.error => (Icons.error_outline, AppColors.danger),
      ToolChipStatus.pending => (Icons.pending_outlined, AppColors.warning),
      ToolChipStatus.rejected => (Icons.block, scheme.onSurfaceVariant),
      ToolChipStatus.consent => (Icons.lock_outline, AppColors.warning),
    };
    final suffix = switch (entry.status) {
      ToolChipStatus.error => ' · failed',
      ToolChipStatus.pending => ' · awaiting approval',
      ToolChipStatus.rejected => ' · not done',
      ToolChipStatus.consent => ' · needs consent',
      _ => '',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm + 2,
            vertical: 5,
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: AppRadii.chip,
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '${entry.label}$suffix',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Approve / Edit / Reject card for a pending write, or Allow / Not now for
/// a consent request.
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
    final t = Theme.of(context).textTheme;
    final accent = pending.isConsent ? AppColors.warning : AppColors.brand;
    return AppCard(
      accent: accent,
      semanticLabel: pending.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                pending.isConsent ? Icons.lock_outline : Icons.edit_note,
                color: accent,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(pending.title, style: t.titleSmall)),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final line in pending.summary)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(line, style: t.bodyMedium),
            ),
          if (!pending.isConsent)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                'Nothing is saved until you approve.',
                style: t.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              FilledButton(
                onPressed: () => onApprove(null),
                child: Text(pending.isConsent ? 'Allow' : 'Approve'),
              ),
              if (!pending.isConsent)
                OutlinedButton(
                  onPressed: () async {
                    final edited = await showDialog<Map<String, Object?>>(
                      context: context,
                      builder: (_) => EditArgsDialog(pending: pending),
                    );
                    if (edited != null) onApprove(edited);
                  },
                  child: const Text('Edit'),
                ),
              TextButton(
                onPressed: onReject,
                child: Text(pending.isConsent ? 'Not now' : 'Reject'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Generic editor for tool arguments: one field per scalar leaf (including
/// leaves of objects inside arrays, e.g. items[0].calories). The result is
/// validated against the tool schema before it can be approved.
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
    return AlertDialog(
      title: Text('Edit · ${widget.pending.title}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final l in _leaves)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: TextField(
                    controller: l.controller,
                    keyboardType: l.original is num
                        ? const TextInputType.numberWithOptions(decimal: true)
                        : TextInputType.text,
                    decoration: InputDecoration(labelText: l.label),
                  ),
                ),
              for (final e in _errors)
                Text(
                  e,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: AppColors.danger),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final edited = _build();
            final spec = toolByName(widget.pending.toolName);
            final errors = spec == null
                ? const <String>[]
                : const ToolArgsValidator().validate(spec.inputSchema, edited);
            if (errors.isNotEmpty) {
              setState(() => _errors = errors.take(4).toList());
              return;
            }
            Navigator.pop(context, edited);
          },
          child: const Text('Approve edited'),
        ),
      ],
    );
  }
}
