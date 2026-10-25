import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/util/format.dart';
import '../../application/health_permissions.dart';
import '../../application/health_providers.dart';
import '../../application/health_sync_service.dart';
import '../../domain/health_types.dart';

/// Per-card permission state.
enum GroupAccess { unavailable, notEnabled, notGranted, granted }

GroupAccess groupAccess(
  HealthGroup group, {
  HealthDiagnostics? diagnostics,
  Set<HealthGroup>? enabled,
}) {
  if (diagnostics == null || diagnostics.sdk != HcSdkStatus.available) {
    return GroupAccess.unavailable;
  }
  if (!(enabled ?? const {}).contains(group)) return GroupAccess.notEnabled;
  if (!diagnostics.groupPartiallyGranted(group)) return GroupAccess.notGranted;
  return GroupAccess.granted;
}

/// Runs a sync and reports the outcome in a snackbar.
Future<void> runHealthSync(
  BuildContext context,
  WidgetRef ref, {
  SyncTrigger trigger = SyncTrigger.manual,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final result = await ref
      .read(healthSyncServiceProvider)
      .sync(trigger: trigger);
  ref.invalidate(healthDiagnosticsProvider);
  final msg = switch (result.outcome) {
    SyncOutcome.ok => 'Synced from Health Connect',
    SyncOutcome.partial =>
      'Synced, but some data types failed. See Health Connect status.',
    SyncOutcome.failed => 'Sync failed. See Health Connect status for details.',
    SyncOutcome.unavailable => 'Health Connect is not available on this phone.',
    SyncOutcome.notEnabled =>
      'Choose which data to share in Health Connect setup first.',
    SyncOutcome.notPermitted =>
      'Health Connect permissions are missing or were revoked.',
    SyncOutcome.skipped => 'Synced recently',
  };
  messenger?.showSnackBar(SnackBar(content: Text(msg)));
}

/// "Last synced 12 min ago" line + sync button. Never claims live data.
class SyncStatusRow extends ConsumerWidget {
  const SyncStatusRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final conn = ref.watch(healthConnectionProvider).value;
    final syncing = ref.watch(healthSyncingProvider).value ?? false;
    final now = ref.watch(clockProvider).now();
    final last = conn?.lastSyncAt;
    final text = syncing
        ? 'Syncing with Health Connect…'
        : last == null
        ? 'Not synced from Health Connect yet'
        : 'Last synced ${Fmt.ago(last, now)} · refreshes on open, '
              'resume or pull-to-refresh';
    return Semantics(
      liveRegion: true,
      child: Row(
        children: [
          Icon(Icons.sync, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          SyncButton(compact: true, syncing: syncing),
        ],
      ),
    );
  }
}

class SyncButton extends ConsumerWidget {
  const SyncButton({super.key, this.compact = false, this.syncing});
  final bool compact;
  final bool? syncing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = syncing ?? (ref.watch(healthSyncingProvider).value ?? false);
    final icon = busy
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.refresh);
    if (compact) {
      return IconButton(
        tooltip: busy ? 'Syncing' : 'Sync now',
        onPressed: busy ? null : () => runHealthSync(context, ref),
        icon: icon,
      );
    }
    return FilledButton.tonalIcon(
      onPressed: busy ? null : () => runHealthSync(context, ref),
      icon: icon,
      label: Text(busy ? 'Syncing…' : 'Sync now'),
    );
  }
}

/// Explanation sheet shown BEFORE the Health Connect permission dialog.
/// Returns the enable result, or null when the user cancelled.
Future<GroupEnableResult?> showHealthPermissionSheet(
  BuildContext context,
  WidgetRef ref,
  HealthGroup group,
) async {
  final proceed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _PermissionSheet(group: group),
  );
  if (proceed != true || !context.mounted) return null;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final result = await ref
      .read(healthPermissionControllerProvider)
      .enableGroup(group);
  ref.invalidate(healthDiagnosticsProvider);
  messenger?.showSnackBar(
    SnackBar(
      content: Text(switch (result) {
        GroupEnableResult.granted => '${group.label} data enabled. Syncing…',
        GroupEnableResult.partial =>
          '${group.label}: some permissions were not granted. '
              'Only the granted types will sync.',
        GroupEnableResult.denied =>
          'No ${group.label.toLowerCase()} permission was granted. '
              'You can change this in Health Connect at any time.',
        GroupEnableResult.unavailable =>
          'Health Connect is not available. Install or update it first.',
      }),
    ),
  );
  return result;
}

class _PermissionSheet extends StatelessWidget {
  const _PermissionSheet({required this.group});
  final HealthGroup group;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          0,
          AppSpacing.gutter,
          AppSpacing.xl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                'Share ${group.label.toLowerCase()} data?',
                style: t.titleLarge,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(group.description, style: t.bodyMedium),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Athlete OS will ask for READ access to:',
              style: t.labelLarge,
            ),
            const SizedBox(height: AppSpacing.xs),
            for (final type in group.types)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 16,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(type.label, style: t.bodyMedium),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              '• Read-only: we never write to Health Connect.\n'
              '• Data is stored on this phone only.\n'
              '• Syncs happen when the app is open (no background access), '
              'so values are as of the last sync — never live.\n'
              '• You can revoke access any time in Health Connect.',
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.xl),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Not now'),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Continue'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Manual steps entry for [localDate]. Stored with origin 'manual'.
Future<void> showManualStepsDialog(
  BuildContext context,
  WidgetRef ref, {
  required String localDate,
  int? initial,
}) async {
  final value = await showDialog<int>(
    context: context,
    builder: (ctx) => _NumberDialog(
      title: 'Enter steps',
      label: 'Steps on ${Fmt.weekdayDayMonth(LocalDates.parse(localDate))}',
      helper:
          'Saved as a manual entry. If Health Connect has data for this day, '
          'the Health Connect value is shown and your entry is kept as '
          'secondary.',
      initial: initial?.toString(),
      decimals: false,
      validate: (v) => v == null || v < 0 || v > 200000
          ? 'Enter a number between 0 and 200,000'
          : null,
    ),
  );
  if (value == null) return;
  await ref
      .read(healthRepositoryProvider)
      .setManualSteps(localDate, value.round());
}

/// Manual weight entry. Stored with origin 'manual', device 'manual'.
Future<void> showManualWeightDialog(BuildContext context, WidgetRef ref) async {
  final value = await showDialog<num>(
    context: context,
    builder: (ctx) => _NumberDialog(
      title: 'Add weight',
      label: 'Weight (kg)',
      helper: 'Saved as a manual entry with the current time.',
      decimals: true,
      validate: (v) => v == null || v < 20 || v > 400
          ? 'Enter a weight between 20 and 400 kg'
          : null,
    ),
  );
  if (value == null) return;
  await ref.read(healthRepositoryProvider).addManualWeight(value.toDouble());
}

class _NumberDialog extends StatefulWidget {
  const _NumberDialog({
    required this.title,
    required this.label,
    required this.helper,
    required this.decimals,
    required this.validate,
    this.initial,
  });

  final String title;
  final String label;
  final String helper;
  final bool decimals;
  final String? Function(num? v) validate;
  final String? initial;

  @override
  State<_NumberDialog> createState() => _NumberDialogState();
}

class _NumberDialogState extends State<_NumberDialog> {
  late final _ctrl = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = num.tryParse(_ctrl.text.trim().replaceAll(',', ''));
    final err = widget.validate(v);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.of(context).pop(widget.decimals ? v : v!.round());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: TextInputType.numberWithOptions(
              decimal: widget.decimals,
            ),
            inputFormatters: [
              FilteringTextInputFormatter.allow(
                RegExp(widget.decimals ? r'[0-9.,]' : r'[0-9,]'),
              ),
            ],
            decoration: InputDecoration(
              labelText: widget.label,
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(widget.helper, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

/// Small labelled chip, e.g. "Manual" / "Samsung Health".
class OriginChip extends StatelessWidget {
  const OriginChip(this.label, {super.key, this.color});
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: AppRadii.chip,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: c),
      ),
    );
  }
}

/// Fire-and-forget helper for buttons.
void fireAndForget(Future<void> f) => unawaited(f.catchError((_) {}));
