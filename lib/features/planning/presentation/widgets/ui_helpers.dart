import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';

/// "Mon 3 Nov 2026" for a YYYY-MM-DD key.
String formatDateKey(String key, {String pattern = 'EEE d MMM yyyy'}) {
  try {
    return DateFormat(pattern).format(LocalDates.parse(key));
  } catch (_) {
    return key;
  }
}

/// Shows a date picker and returns the chosen date as YYYY-MM-DD.
Future<String?> pickDateKey(
  BuildContext context, {
  String? initial,
  DateTime? first,
  DateTime? last,
  String? helpText,
}) async {
  final now = DateTime.now();
  DateTime init;
  try {
    init = initial != null ? LocalDates.parse(initial) : now;
  } catch (_) {
    init = now;
  }
  final f = first ?? DateTime(now.year - 5);
  final l = last ?? DateTime(now.year + 5);
  if (init.isBefore(f)) init = f;
  if (init.isAfter(l)) init = l;
  final picked = await showDatePicker(
    context: context,
    initialDate: init,
    firstDate: f,
    lastDate: l,
    helpText: helpText,
  );
  return picked == null ? null : LocalDates.key(picked);
}

/// Simple yes/no confirmation.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Destructive confirmation that requires typing [word] exactly.
Future<bool> confirmTyped(
  BuildContext context, {
  required String title,
  required String message,
  String word = 'DELETE',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) =>
        _TypedConfirmDialog(title: title, message: message, word: word),
  );
  return ok ?? false;
}

class _TypedConfirmDialog extends StatefulWidget {
  const _TypedConfirmDialog({
    required this.title,
    required this.message,
    required this.word,
  });
  final String title;
  final String message;
  final String word;

  @override
  State<_TypedConfirmDialog> createState() => _TypedConfirmDialogState();
}

class _TypedConfirmDialogState extends State<_TypedConfirmDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = _c.text.trim() == widget.word;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          const SizedBox(height: AppSpacing.md),
          Text('Type ${widget.word} to confirm.'),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _c,
            autofocus: true,
            decoration: InputDecoration(hintText: widget.word),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: matches ? () => Navigator.pop(context, true) : null,
          child: const Text('Delete permanently'),
        ),
      ],
    );
  }
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Card header row: icon + title + optional trailing.
class CardTitle extends StatelessWidget {
  const CardTitle({
    super.key,
    required this.icon,
    required this.title,
    this.color,
    this.trailing,
  });
  final IconData icon;
  final String title;
  final Color? color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color ?? AppColors.brand),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        ?trailing,
      ],
    );
  }
}

/// Muted explanatory text.
class Hint extends StatelessWidget {
  const Hint(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
  );
}
