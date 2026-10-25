import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/util/format.dart';
import '../../../../data/db/database.dart';
import '../../../../data/repositories/integration_status_repository.dart';

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

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final IntegrationDisplayStatus status;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Status: ${status.label}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 4,
        ),
        decoration: BoxDecoration(
          color: status.color.withValues(alpha: 0.14),
          borderRadius: AppRadii.chip,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(status.icon, size: 14, color: status.color),
            const SizedBox(width: 4),
            Text(
              status.label,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: status.color),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact sync row for the Train tab: name, status, last sync, sync button.
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
    final scheme = Theme.of(context).colorScheme;
    final last = row?.lastSyncAt;
    final sub = status == IntegrationDisplayStatus.connected
        ? (last == null
              ? 'Not synced yet'
              : 'Synced ${Fmt.ago(last.toLocal(), now)}')
        : status.label;
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: t.labelLarge),
              Text(
                sub,
                style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        if (status == IntegrationDisplayStatus.connected)
          syncing
              ? const Padding(
                  padding: EdgeInsets.all(AppSpacing.md),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  tooltip: 'Sync $name now',
                  onPressed: onSync,
                  icon: const Icon(Icons.sync),
                )
        else
          TextButton(
            onPressed: onSetup,
            child: Text(
              status == IntegrationDisplayStatus.error ? 'Fix' : 'Set up',
            ),
          ),
      ],
    );
  }
}

String weekLabel(String weekStartKey) {
  final d = LocalDates.parse(weekStartKey);
  return '${d.day}/${d.month}';
}
