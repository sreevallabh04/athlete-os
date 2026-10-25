import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/util/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../train/presentation/widgets/hud_kit.dart';
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

/// Runs a sync and reports the outcome in a snackbar (with a matching
/// haptic).
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
  switch (result.outcome) {
    case SyncOutcome.ok:
      Haptics.success();
    case SyncOutcome.failed ||
        SyncOutcome.notPermitted ||
        SyncOutcome.unavailable:
      Haptics.warning();
    default:
      break;
  }
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

/// "Last synced 12 min ago" strip + sync button. Never claims live data.
class SyncStatusRow extends ConsumerWidget {
  const SyncStatusRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = context.hud;
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
    final c = syncing
        ? hud.accent
        : last == null
        ? AppColors.warning
        : AppColors.success;
    return Semantics(
      liveRegion: true,
      child: GlassPanel(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.xs,
          AppSpacing.xs,
        ),
        radius: AppRadii.md,
        child: Row(
          children: [
            HudDot(color: c, size: 6, pulse: syncing),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(text, style: hud.mono(size: 10.5))),
            SyncButton(compact: true, syncing: syncing),
          ],
        ),
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
    if (compact) {
      return IconButton(
        tooltip: busy ? 'Syncing' : 'Sync now',
        onPressed: busy ? null : () => runHealthSync(context, ref),
        icon: busy
            ? const HudSpinner(size: 18)
            : const Icon(Icons.sync, size: 20),
      );
    }
    return HudButton.secondary(
      label: busy ? 'Syncing…' : 'Sync now',
      icon: Icons.sync,
      loading: busy,
      expand: true,
      onPressed: busy ? null : () => runHealthSync(context, ref),
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
  final proceed = await showHudBottomSheet<bool>(
    context,
    title: 'Share ${group.label.toLowerCase()} data?',
    builder: (ctx) => _PermissionSheet(group: group),
  );
  if (proceed != true || !context.mounted) return null;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final result = await ref
      .read(healthPermissionControllerProvider)
      .enableGroup(group);
  ref.invalidate(healthDiagnosticsProvider);
  if (result == GroupEnableResult.granted) {
    Haptics.success();
  } else if (result != GroupEnableResult.partial) {
    Haptics.warning();
  }
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
    final hud = context.hud;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(group.description, style: t.bodyMedium),
        const SizedBox(height: AppSpacing.lg),
        Text('READ ACCESS ONLY', style: hud.label(size: 11)),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.xs + 2,
          runSpacing: AppSpacing.xs,
          children: [
            for (final type in group.types)
              HudChip(label: type.label, icon: Icons.check, uppercase: false),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        for (final line in const [
          'Read-only: Athlete OS never writes to Health Connect.',
          'Data stays on this phone.',
          'Syncs when the app is open (no background access), so values are '
              'as of the last sync — never live.',
          'Revoke any time in Health Connect.',
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: AppSpacing.sm),
                  child: HudDot(color: hud.accent, size: 4),
                ),
                Expanded(
                  child: Text(
                    line,
                    style: t.bodySmall?.copyWith(color: hud.textMuted),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
        HudButton(
          label: 'Continue',
          expand: true,
          onPressed: () => Navigator.of(context).pop(true),
        ),
        const SizedBox(height: AppSpacing.xs),
        HudButton.ghost(
          label: 'Not now',
          expand: true,
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ],
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
  final value = await showHudBottomSheet<num>(
    context,
    title: 'Enter steps',
    builder: (ctx) => _NumberSheet(
      label: 'Steps on ${Fmt.weekdayDayMonth(LocalDates.parse(localDate))}',
      helper:
          'Saved as a manual entry. If Health Connect has data for this day, '
          'the Health Connect value is shown and your entry is kept as '
          'secondary.',
      initial: initial?.toString(),
      decimals: false,
      quick: const [1000, 2500, 5000],
      validate: (v) => v == null || v < 0 || v > 200000
          ? 'Enter a number between 0 and 200,000'
          : null,
    ),
  );
  if (value == null) return;
  await ref
      .read(healthRepositoryProvider)
      .setManualSteps(localDate, value.round());
  Haptics.success();
}

/// Manual weight entry. Stored with origin 'manual', device 'manual'.
Future<void> showManualWeightDialog(BuildContext context, WidgetRef ref) async {
  final value = await showHudBottomSheet<num>(
    context,
    title: 'Add weight',
    builder: (ctx) => _NumberSheet(
      label: 'Weight (kg)',
      helper:
          'Saved as a manual entry with the current time. Weigh in the '
          'morning, after the bathroom, for comparable numbers.',
      decimals: true,
      validate: (v) => v == null || v < 20 || v > 400
          ? 'Enter a weight between 20 and 400 kg'
          : null,
    ),
  );
  if (value == null) return;
  await ref.read(healthRepositoryProvider).addManualWeight(value.toDouble());
  Haptics.success();
}

class _NumberSheet extends StatefulWidget {
  const _NumberSheet({
    required this.label,
    required this.helper,
    required this.decimals,
    required this.validate,
    this.initial,
    this.quick = const [],
  });

  final String label;
  final String helper;
  final bool decimals;
  final String? Function(num? v) validate;
  final String? initial;

  /// Quick-add increments (e.g. +1,000 steps).
  final List<int> quick;

  @override
  State<_NumberSheet> createState() => _NumberSheetState();
}

class _NumberSheetState extends State<_NumberSheet> {
  late final _ctrl = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  num? get _value => num.tryParse(_ctrl.text.trim().replaceAll(',', ''));

  void _submit() {
    final v = _value;
    final err = widget.validate(v);
    if (err != null) {
      Haptics.warning();
      setState(() => _error = err);
      return;
    }
    Navigator.of(context).pop(widget.decimals ? v : v!.round());
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
            style: hud.number(size: 28),
            decoration: InputDecoration(
              labelText: widget.label,
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (widget.quick.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                for (final q in widget.quick)
                  HudChip(
                    label: '+${Fmt.integer(q)}',
                    onTap: () => setState(() {
                      _ctrl.text = Fmt.integer((_value ?? 0) + q)
                          .replaceAll(',', '');
                      _error = null;
                    }),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Text(
            widget.helper,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: hud.textMuted),
          ),
          const SizedBox(height: AppSpacing.lg),
          HudButton(label: 'Save', expand: true, onPressed: _submit),
        ],
      ),
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
    final hud = context.hud;
    final c = color ?? hud.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadii.xs),
        border: Border.all(color: c.withValues(alpha: 0.25)),
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

/// "06:00" from minutes after midnight.
String clockLabel(int minutes) =>
    '${(minutes ~/ 60 % 24).toString().padLeft(2, '0')}:'
    '${(minutes % 60).toString().padLeft(2, '0')}';

/// Honest phone-only step counting steps for this user's OPPO (Android 13).
/// [hcInstalled], [granted] and [synced] tick steps off as they happen.
List<HudStep> stepsSetup({
  required bool hcInstalled,
  required bool hasStepData,
  required bool granted,
  required bool synced,
  Widget? installAction,
  Widget? grantAction,
}) => [
  HudStep(
    'Install Health Connect',
    'On Android 13 it is a separate app from the Play Store (Android 14+ '
        'has it built in).',
    done: hcInstalled,
    action: hcInstalled ? null : installAction,
  ),
  HudStep(
    'Add a phone step counter',
    'Health Connect does not count steps itself. With no watch, use a '
        'phone step counter that writes to it (e.g. Google Fit or Samsung '
        'Health) and turn on its Health Connect sync.',
    done: hasStepData,
  ),
  HudStep(
    'Allow Athlete OS to read',
    'Grant read access to Activity (steps, distance, exercise).',
    done: granted,
    action: granted || !hcInstalled ? null : grantAction,
  ),
  HudStep(
    'Sync',
    'Pull to refresh or tap Sync. Phone steps arrive in batches, so they '
        'can lag a little.',
    done: synced,
  ),
];
