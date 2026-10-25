import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../application/providers.dart';
import '../../data/assistant_platform.dart';
import '../../domain/sensitivity_classifier.dart';

/// Shows an explanation BEFORE sending the user to a system settings page.
/// Returns true only when the user chose to continue.
Future<bool> explainBeforeSettings(
  BuildContext context, {
  required String title,
  required String body,
  IconData icon = Icons.info_outline,
  String continueLabel = 'Open settings',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(icon),
      title: Text(title),
      content: SingleChildScrollView(child: Text(body)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(continueLabel),
        ),
      ],
    ),
  );
  return ok == true;
}

const notificationAccessExplanation =
    'Athlete OS will be able to read notifications ONLY from the messaging '
    'apps you switch on in Assistant settings (all are off by default). '
    'Notifications from every other app are ignored immediately and never '
    'stored.\n\n'
    'What it does with them: shows summaries, prepares reply drafts, and — '
    'only when you tap Send on a specific draft — passes your reply to that '
    "notification's own Reply button (the same way smartwatches do).\n\n"
    'Captured text stays on this phone, is deleted after the retention period '
    '(7 days by default), and is sent to AI only if you allow it.\n\n'
    'Android will show its "Notification access" page next. Turn on '
    '"Athlete OS assistant". If it is greyed out (sideloaded app on Android '
    '13), open App info › ⋮ › Allow restricted settings first.\n\n'
    'You can revoke this at any time on the same page.';

/// Explains notification access, then (only if the user agrees) opens the
/// system page.
Future<void> requestNotificationAccess(
  BuildContext context,
  WidgetRef ref,
) async {
  final ok = await explainBeforeSettings(
    context,
    title: 'Allow notification access?',
    body: notificationAccessExplanation,
    icon: Icons.notifications_outlined,
  );
  if (!ok) return;
  await ref.read(assistantPlatformProvider).openListenerSettings();
  ref.invalidate(assistantDeviceStatusProvider);
}

/// Small coloured pill.
class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, required this.color, this.icon});
  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: AppRadii.chip,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    ),
  );
}

class FlagChips extends StatelessWidget {
  const FlagChips(this.flags, {super.key});
  final Set<SensitivityFlag> flags;

  @override
  Widget build(BuildContext context) {
    if (flags.isEmpty) {
      return const StatusPill(
        'No risk flags',
        color: AppColors.success,
        icon: Icons.check,
      );
    }
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: [
        for (final f in flags)
          StatusPill(
            f.label,
            color: f.isContent ? AppColors.danger : AppColors.warning,
            icon: f.isContent ? Icons.shield_outlined : Icons.help_outline,
          ),
      ],
    );
  }
}

/// The big emergency stop used on the assistant and capabilities screens.
class KillSwitchCard extends ConsumerWidget {
  const KillSwitchCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final killed =
        ref.watch(assistantSettingsProvider).value?.killSwitch ?? false;
    final t = Theme.of(context).textTheme;
    return AppCard(
      accent: killed ? AppColors.danger : AppColors.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                killed ? Icons.block : Icons.shield_moon_outlined,
                color: killed ? AppColors.danger : AppColors.success,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  killed
                      ? 'Emergency stop is ON — nothing is captured, drafted '
                            'or sent.'
                      : 'Assistant automation is allowed by your settings.',
                  style: t.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              key: const Key('kill_switch_button'),
              style: FilledButton.styleFrom(
                backgroundColor: killed ? AppColors.success : AppColors.danger,
                foregroundColor: Colors.white,
              ),
              onPressed: () =>
                  ref.read(assistantControllerProvider).setKillSwitch(!killed),
              icon: Icon(killed ? Icons.play_arrow : Icons.stop_circle),
              label: Text(
                killed ? 'Resume assistant' : 'Emergency stop',
                style: t.titleMedium?.copyWith(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String appLabelFor(String pkg, Map<String, String> labels) =>
    labels[pkg] ?? pkg;

String formatMinutes(int m) {
  final h = m ~/ 60, mm = m % 60;
  return '${h.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
}

/// Platform convenience for widgets that only need the interface.
AssistantPlatform platformOf(WidgetRef ref) =>
    ref.read(assistantPlatformProvider);
