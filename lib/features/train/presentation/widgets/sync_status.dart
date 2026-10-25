import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/util/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../data/db/database.dart';
import '../../../../data/repositories/integration_status_repository.dart';
import 'hud_kit.dart';

/// Display status of an integration, combining build config and DB state.
enum IntegrationDisplayStatus {
  connected('Connected', AppColors.success, Icons.check_circle),
  disconnected('Disconnected', AppColors.info, Icons.link_off),
  needsSetup('Needs setup', AppColors.warning, Icons.settings),
  awaitingCredentials(
    'Awaiting credentials',
    AppColors.warning,
    Icons.hourglass_empty,
  ),
  error('Error', AppColors.danger, Icons.error_outline);

  const IntegrationDisplayStatus(this.label, this.color, this.icon);
  final String label;
  final Color color;
  final IconData icon;
}

IntegrationDisplayStatus displayStatus(
  IntegrationConnection? row, {
  bool configured = true,
  bool needsSetupWhenMissing = true,
}) {
  if (!configured) return IntegrationDisplayStatus.awaitingCredentials;
  switch (row?.status) {
    case ConnectionStates.connected:
      return IntegrationDisplayStatus.connected;
    case ConnectionStates.error:
      return IntegrationDisplayStatus.error;
    case ConnectionStates.awaitingCredentials:
      return IntegrationDisplayStatus.awaitingCredentials;
    case ConnectionStates.disconnected:
      return IntegrationDisplayStatus.disconnected;
    case ConnectionStates.needsSetup:
      return IntegrationDisplayStatus.needsSetup;
    default:
      return needsSetupWhenMissing
          ? IntegrationDisplayStatus.needsSetup
          : IntegrationDisplayStatus.disconnected;
  }
}

/// HUD status pill with a glowing dot (pulses while connected).
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final IntegrationDisplayStatus status;

  @override
  Widget build(BuildContext context) {
    final c = status.color;
    return Semantics(
      label: 'Status: ${status.label}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 2, 9, 2),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadii.xs),
          border: Border.all(color: c.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HudDot(
              color: c,
              size: 5,
              pulse: status == IntegrationDisplayStatus.connected,
            ),
            Text(
              status.label,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: c, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// Status + last sync + action for one import source (used in the Train
/// tab's sync sheet).
class SyncStatusTile extends StatelessWidget {
  const SyncStatusTile({
    super.key,
    required this.name,
    required this.color,
    required this.row,
    required this.configured,
    required this.syncing,
    required this.onSync,
    required this.onSetup,
    required this.now,
  });

  final String name;
  final Color color;
  final IntegrationConnection? row;
  final bool configured;
  final bool syncing;
  final VoidCallback onSync;
  final VoidCallback onSetup;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final status = displayStatus(row, configured: configured);
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final last = row?.lastSyncAt;
    final connected = status == IntegrationDisplayStatus.connected;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            HudBadge(
              text: name.substring(0, 2).toUpperCase(),
              color: color,
              size: 44,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StatusChip(status),
                  const SizedBox(height: 4),
                  Text(
                    connected
                        ? (last == null
                              ? 'Not synced yet'
                              : 'Last synced ${Fmt.ago(last.toLocal(), now)}')
                        : status == IntegrationDisplayStatus.awaitingCredentials
                        ? 'This build has no credentials for $name yet.'
                        : 'Not connected on this phone.',
                    style: t.bodySmall?.copyWith(color: hud.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (row?.lastError != null && !connected) ...[
          const SizedBox(height: AppSpacing.md),
          NoticeBanner(
            message: 'Last error: ${row!.lastError}',
            color: AppColors.danger,
            icon: Icons.error_outline,
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        if (connected)
          HudButton(
            label: syncing ? 'Syncing…' : 'Sync $name now',
            icon: Icons.sync,
            loading: syncing,
            expand: true,
            onPressed: syncing ? null : onSync,
          )
        else
          HudButton.secondary(
            label: status == IntegrationDisplayStatus.error
                ? 'Fix in Integrations'
                : 'Set up in Integrations',
            icon: Icons.settings_outlined,
            expand: true,
            onPressed: onSetup,
          ),
      ],
    );
  }
}

String weekLabel(String weekStartKey) {
  final d = LocalDates.parse(weekStartKey);
  return '${d.day}/${d.month}';
}
