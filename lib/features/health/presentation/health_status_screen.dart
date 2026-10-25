import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../application/health_permissions.dart';
import '../application/health_providers.dart';
import '../application/health_sync_service.dart';
import '../domain/health_types.dart';
import 'widgets/health_widgets.dart';

class HealthStatusScreen extends ConsumerWidget {
  const HealthStatusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diag = ref.watch(healthDiagnosticsProvider);
    return AppPage(
      title: 'Health Connect',
      subtitle: 'Samsung Health → Health Connect → Athlete OS',
      onRefresh: () async {
        ref.invalidate(healthDiagnosticsProvider);
        await runHealthSync(context, ref, trigger: SyncTrigger.pullToRefresh);
      },
      children: [
        diag.when(
          loading: () => const LoadingState(),
          error: (e, _) => ErrorState(
            message: 'Could not check Health Connect.',
            onRetry: () => ref.invalidate(healthDiagnosticsProvider),
          ),
          data: (d) => _SdkCard(diagnostics: d),
        ),
        const SizedBox(height: AppSpacing.md),
        const _ConnectionCard(),
        if (diag.value?.sdk == HcSdkStatus.available) ...[
          const SectionHeader(
            'Data you share',
            subtitle: 'Read-only. Turn on only what you use.',
          ),
          _GroupsCard(diagnostics: diag.value!),
          const SizedBox(height: AppSpacing.md),
          _HistoryCard(diagnostics: diag.value!),
        ],
        const SectionHeader('Set up Samsung Health'),
        const _SetupSteps(),
        const SectionHeader('Troubleshooting'),
        const _Troubleshooting(),
      ],
    );
  }
}

class _SdkCard extends ConsumerWidget {
  const _SdkCard({required this.diagnostics});
  final HealthDiagnostics diagnostics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sdk = diagnostics.sdk;
    final (color, icon, message) = switch (sdk) {
      HcSdkStatus.available => (
        AppColors.success,
        Icons.check_circle_outline,
        'Health Connect is available on this phone.',
      ),
      HcSdkStatus.needsInstall => (
        AppColors.warning,
        Icons.download_outlined,
        'Install Health Connect from the Play Store (needed on Android 13 '
            'and lower; built into Android 14+).',
      ),
      HcSdkStatus.needsUpdate => (
        AppColors.warning,
        Icons.system_update_outlined,
        'Health Connect needs an update before Athlete OS can read data.',
      ),
      HcSdkStatus.unsupported => (
        AppColors.danger,
        Icons.block,
        'Health Connect is not supported on this device. You can still '
            'enter steps and weight manually.',
      ),
    };
    return AppCard(
      accent: color,
      semanticLabel: 'Health Connect status: ${sdk.label}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: AppSpacing.sm),
              Text(sdk.label, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(message),
          if (sdk == HcSdkStatus.needsInstall ||
              sdk == HcSdkStatus.needsUpdate) ...[
            const SizedBox(height: AppSpacing.md),
            FilledButton(
              onPressed: () async {
                await ref.read(healthDataSourceProvider).installOrUpdate();
                ref.invalidate(healthDiagnosticsProvider);
              },
              child: Text(
                sdk == HcSdkStatus.needsInstall
                    ? 'Install Health Connect'
                    : 'Update Health Connect',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ConnectionCard extends ConsumerWidget {
  const _ConnectionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final conn = ref.watch(healthConnectionProvider).value;
    final now = ref.watch(clockProvider).now();
    final status = conn?.status ?? ConnectionStates.needsSetup;
    final statusLabel = switch (status) {
      ConnectionStates.connected => 'Connected',
      ConnectionStates.error => 'Error',
      ConnectionStates.disconnected => 'Disconnected',
      _ => 'Needs setup',
    };
    final lastSync = conn?.lastSyncAt;
    final error = conn?.lastError;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: StatTile(label: 'Status', value: statusLabel),
              ),
              Expanded(
                child: StatTile(
                  label: 'Last synced',
                  value: lastSync == null ? 'Never' : Fmt.ago(lastSync, now),
                  sub: lastSync == null
                      ? null
                      : '${Fmt.dayMonth(lastSync)}, ${Fmt.time(lastSync)}',
                ),
              ),
            ],
          ),
          if (error != null && error.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            NoticeBanner(
              message: 'Last error: ${redactSecrets(error)}',
              color: AppColors.danger,
              icon: Icons.error_outline,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Text(
            'Sync runs when you open or return to the app, pull to refresh, '
            'or tap Sync now. There is no background sync, so data is as of '
            'the last sync.',
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              const SyncButton(),
              OutlinedButton.icon(
                onPressed: () => _openSettings(context, ref),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open Health Connect settings'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openSettings(BuildContext context, WidgetRef ref) async {
    final opened = await ref.read(healthDataSourceProvider).openSettings();
    if (opened || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open Health Connect'),
        content: const Text(
          'Android 14 and newer: Settings › Security & privacy › Privacy › '
          'Health Connect (or search "Health Connect" in Settings).\n\n'
          'Android 13 and older: open the Health Connect app.\n\n'
          'Then go to App permissions › Athlete OS to review access.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    ref.invalidate(healthDiagnosticsProvider);
  }
}

class _GroupsCard extends ConsumerWidget {
  const _GroupsCard({required this.diagnostics});
  final HealthDiagnostics diagnostics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(healthEnabledGroupsProvider).value ?? const {};
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        children: [
          for (final g in HealthGroup.values)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(g.label, style: t.titleSmall)),
                      Switch(
                        value: enabled.contains(g),
                        onChanged: (on) async {
                          if (on) {
                            await showHealthPermissionSheet(context, ref, g);
                          } else {
                            await ref
                                .read(healthPermissionControllerProvider)
                                .disableGroup(g);
                            if (context.mounted) {
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '${g.label} import turned off. To revoke '
                                    'the permission itself, use Health '
                                    'Connect settings.',
                                  ),
                                ),
                              );
                            }
                          }
                        },
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final type in g.types)
                        Semantics(
                          label:
                              '${type.label}: '
                              '${diagnostics.granted(type) ? 'granted' : 'not granted'}',
                          excludeSemantics: true,
                          child: OriginChip(
                            '${diagnostics.granted(type) ? '✓' : '✗'} '
                            '${type.label}',
                            color: diagnostics.granted(type)
                                ? AppColors.success
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  if (enabled.contains(g) &&
                      !diagnostics.groupPartiallyGranted(g))
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      child: Text(
                        'Enabled here but no permission granted in Health '
                        'Connect — it may have been revoked.',
                        style: t.bodySmall?.copyWith(color: AppColors.warning),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HistoryCard extends ConsumerWidget {
  const _HistoryCard({required this.diagnostics});
  final HealthDiagnostics diagnostics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('History access (optional)', style: t.titleSmall),
              ),
              OriginChip(
                !diagnostics.historyAvailable
                    ? 'Not available'
                    : diagnostics.historyAuthorized
                    ? 'Granted'
                    : 'Not granted',
                color: diagnostics.historyAuthorized ? AppColors.success : null,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Without it, Health Connect only shares data from 30 days before '
            'you first granted access. Athlete OS currently imports the last '
            '30 days either way.',
            style: t.bodySmall,
          ),
          if (diagnostics.historyAvailable &&
              !diagnostics.historyAuthorized) ...[
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton(
              onPressed: () async {
                final ok = await ref
                    .read(healthPermissionControllerProvider)
                    .requestHistory();
                ref.invalidate(healthDiagnosticsProvider);
                if (context.mounted) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(
                      content: Text(
                        ok
                            ? 'History access granted'
                            : 'History access not granted',
                      ),
                    ),
                  );
                }
              },
              child: const Text('Request history access'),
            ),
          ],
        ],
      ),
    );
  }
}

class _SetupSteps extends StatelessWidget {
  const _SetupSteps();

  static const _steps = [
    (
      'Update Samsung Health',
      'Use Samsung Health 6.22.5 or newer on your phone.',
    ),
    (
      'Turn on Health Connect sync in Samsung Health',
      'Samsung Health › ⋮ › Settings › Health Connect, and allow Samsung '
          'Health to write steps, exercise, heart rate, sleep and weight.',
    ),
    (
      'Grant Athlete OS read access',
      'Use the switches above. Health Connect shows its own permission '
          'screen; allow the types you want.',
    ),
    (
      'Keep your watch syncing',
      'Your Galaxy Watch syncs to Samsung Health on the phone, which then '
          'writes to Health Connect. Keep Bluetooth on and open Samsung '
          'Health occasionally.',
    ),
    (
      'Expect a delay for watch heart rate',
      'Continuous watch heart rate reaches Health Connect in batches, so '
          'recent readings can lag by minutes to hours.',
    ),
    ('Sync in Athlete OS', 'Open the app, pull to refresh, or tap Sync now.'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 12,
                    child: Text('${i + 1}', style: t.labelSmall),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_steps[i].$1, style: t.titleSmall),
                        Text(_steps[i].$2, style: t.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Text(
            'Samsung does not offer an open direct API for third-party apps '
            '(its Health Data SDK requires partner approval), so Health '
            'Connect is the supported path.',
            style: t.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Troubleshooting extends StatelessWidget {
  const _Troubleshooting();

  static const _items = [
    (
      'Steps are missing or lower than Samsung Health',
      'Check Samsung Health › Settings › Health Connect is on and that '
          'Samsung Health has permission to write Steps. In Health Connect › '
          'Data and access › Steps, Samsung Health should be at the top of '
          'the app priority list. Then sync again.',
    ),
    (
      'Old data is missing',
      'Health Connect only shares data from 30 days before you first '
          'granted access unless you grant history access.',
    ),
    (
      'It says permission not granted, but I allowed it',
      'Permissions can be revoked in Health Connect or reset when Health '
          'Connect updates. Toggle the group off and on above to request '
          'again.',
    ),
    (
      'Heart rate looks out of date',
      'The watch syncs heart rate to the phone in batches. Open Samsung '
          'Health to force a sync, then pull to refresh here.',
    ),
    (
      'The same run appears twice',
      'Runs imported from Health Connect are keyed by their Health Connect '
          'id, so re-syncing never duplicates them. A run also imported from '
          'Strava is a separate record from a different source.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (final (q, a) in _items)
            ExpansionTile(
              title: Text(q),
              childrenPadding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              children: [Text(a)],
            ),
        ],
      ),
    );
  }
}
