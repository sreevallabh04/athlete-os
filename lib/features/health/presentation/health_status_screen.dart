import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../train/presentation/widgets/hud_kit.dart';
import '../application/health_permissions.dart';
import '../application/health_providers.dart';
import '../application/health_sync_service.dart';
import '../domain/health_types.dart';
import 'widgets/health_widgets.dart';

/// Health Connect status: SDK + connection, a capability matrix (what each
/// data type feeds, whether it is shared and granted), the phone-only setup
/// path and troubleshooting.
class HealthStatusScreen extends ConsumerWidget {
  const HealthStatusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diag = ref.watch(healthDiagnosticsProvider);
    final steps = ref.watch(stepsHistoryProvider(30)).value;
    final conn = ref.watch(healthConnectionProvider).value;
    final d = diag.value;
    final available = d?.sdk == HcSdkStatus.available;
    final activityGranted =
        d != null && d.groupPartiallyGranted(HealthGroup.activity);
    return AppPage(
      title: 'Health Connect',
      eyebrow: 'PHONE APPS → HEALTH CONNECT → ATHLETE OS',
      onRefresh: () async {
        ref.invalidate(healthDiagnosticsProvider);
        await runHealthSync(context, ref, trigger: SyncTrigger.pullToRefresh);
      },
      children: [
        diag.when(
          loading: () => const ScanlineLoader(height: 120, lines: 0),
          error: (e, _) => ErrorState(
            message: 'Could not check Health Connect.',
            onRetry: () => ref.invalidate(healthDiagnosticsProvider),
          ),
          data: (d) => _SdkCard(diagnostics: d),
        ),
        const SizedBox(height: AppSpacing.md),
        _ConnectionCard(available: available),
        const SectionHeader('Capability matrix', subtitle: 'Read-only access'),
        _MatrixCard(diagnostics: d),
        if (available) ...[
          const SizedBox(height: AppSpacing.md),
          _HistoryCard(diagnostics: d!),
        ],
        const SectionHeader('Set up this phone'),
        AppCard(
          child: HudSteps(
            steps: stepsSetup(
              hcInstalled: available,
              hasStepData:
                  steps?.values.any((s) => s != null && !s.isManual) ?? false,
              granted: activityGranted,
              synced: conn?.lastSyncAt != null,
              installAction: d == null || available
                  ? null
                  : HudButton.secondary(
                      label: d.sdk == HcSdkStatus.needsUpdate
                          ? 'Update Health Connect'
                          : 'Get Health Connect',
                      icon: Icons.download_outlined,
                      compact: true,
                      onPressed: () async {
                        await ref
                            .read(healthDataSourceProvider)
                            .installOrUpdate();
                        ref.invalidate(healthDiagnosticsProvider);
                      },
                    ),
              grantAction: HudButton.secondary(
                label: 'Allow activity',
                icon: Icons.lock_open,
                compact: true,
                onPressed: () => showHealthPermissionSheet(
                  context,
                  ref,
                  HealthGroup.activity,
                ),
              ),
            ),
          ),
        ),
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
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final sdk = diagnostics.sdk;
    final (color, icon, message) = switch (sdk) {
      HcSdkStatus.available => (
        AppColors.success,
        Icons.verified_outlined,
        'Health Connect is installed and reachable on this phone.',
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
    final granted = diagnostics.permissions.values.where((v) => v).length;
    return AppCard(
      accent: color,
      brackets: true,
      semanticLabel: 'Health Connect status: ${sdk.label}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              HudBadge(icon: icon, color: color, size: 48),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SDK STATUS', style: hud.label(size: 11)),
                    Text(
                      sdk.label,
                      style: t.titleLarge?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              if (sdk == HcSdkStatus.available)
                HudReadout(
                  label: 'Types granted',
                  value: '$granted/${HcDataType.values.length}',
                  size: 22,
                  crossAxisAlignment: CrossAxisAlignment.end,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(message, style: t.bodySmall?.copyWith(color: hud.textMuted)),
          if (sdk == HcSdkStatus.needsInstall ||
              sdk == HcSdkStatus.needsUpdate) ...[
            const SizedBox(height: AppSpacing.md),
            HudButton(
              label: sdk == HcSdkStatus.needsInstall
                  ? 'Install Health Connect'
                  : 'Update Health Connect',
              icon: Icons.shop_outlined,
              expand: true,
              onPressed: () async {
                await ref.read(healthDataSourceProvider).installOrUpdate();
                ref.invalidate(healthDiagnosticsProvider);
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _ConnectionCard extends ConsumerWidget {
  const _ConnectionCard({required this.available});
  final bool available;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = context.hud;
    final conn = ref.watch(healthConnectionProvider).value;
    final now = ref.watch(clockProvider).now();
    final status = conn?.status ?? ConnectionStates.needsSetup;
    final (statusLabel, statusColor) = switch (status) {
      ConnectionStates.connected => ('Connected', AppColors.success),
      ConnectionStates.error => ('Error', AppColors.danger),
      ConnectionStates.disconnected => ('Disconnected', hud.textMuted),
      _ => ('Needs setup', AppColors.warning),
    };
    final lastSync = conn?.lastSyncAt;
    final error = conn?.lastError;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: HudReadout(
                  label: 'Status',
                  value: statusLabel,
                  size: 22,
                  color: statusColor,
                ),
              ),
              Expanded(
                child: HudReadout(
                  label: 'Last synced',
                  value: lastSync == null ? 'Never' : Fmt.ago(lastSync, now),
                  caption: lastSync == null
                      ? null
                      : '${Fmt.dayMonth(lastSync)}, ${Fmt.time(lastSync)}',
                  size: 22,
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
            style: hud.mono(size: 10),
          ),
          if (available) ...[
            const SizedBox(height: AppSpacing.md),
            const SyncButton(),
          ],
          const SizedBox(height: AppSpacing.sm),
          HudButton.ghost(
            label: 'Open Health Connect settings',
            icon: Icons.open_in_new,
            expand: true,
            onPressed: () => _openSettings(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _openSettings(BuildContext context, WidgetRef ref) async {
    final opened = await ref.read(healthDataSourceProvider).openSettings();
    if (opened || !context.mounted) return;
    await showHudBottomSheet<void>(
      context,
      title: 'Open Health Connect',
      builder: (ctx) => const HudSteps(
        steps: [
          HudStep(
            'Android 13 and older',
            'Open the Health Connect app from your app drawer.',
          ),
          HudStep(
            'Android 14 and newer',
            'Settings › Security & privacy › Privacy › Health Connect (or '
                'search "Health Connect" in Settings).',
          ),
          HudStep(
            'Review access',
            'App permissions › Athlete OS shows exactly what is shared.',
          ),
        ],
      ),
    );
    ref.invalidate(healthDiagnosticsProvider);
  }
}

/// What each data type feeds inside Athlete OS.
const _feeds = {
  HcDataType.steps: 'Steps ring, habits',
  HcDataType.distance: 'Daily activity',
  HcDataType.activeCalories: 'Active energy',
  HcDataType.totalCalories: 'Energy balance',
  HcDataType.exercise: 'Runs & sessions',
  HcDataType.heartRate: 'Run heart rate',
  HcDataType.restingHeartRate: 'Health overview',
  HcDataType.sleepSession: 'Sleep, readiness',
  HcDataType.weight: 'Weight trend',
};

class _MatrixCard extends ConsumerWidget {
  const _MatrixCard({required this.diagnostics});
  final HealthDiagnostics? diagnostics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final enabled = ref.watch(healthEnabledGroupsProvider).value ?? const {};
    final d = diagnostics;
    final available = d?.sdk == HcSdkStatus.available;
    return AppCard(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('DATA', style: hud.label(size: 10.5))),
              SizedBox(
                width: 120,
                child: Text('FEEDS', style: hud.label(size: 10.5)),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  'ACCESS',
                  textAlign: TextAlign.end,
                  style: hud.label(size: 10.5),
                ),
              ),
            ],
          ),
          if (!available) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Install Health Connect to share any of these.',
              style: t.bodySmall?.copyWith(color: AppColors.warning),
            ),
          ],
          for (final g in HealthGroup.values) ...[
            const HudDivider(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: Text(
                    g.label.toUpperCase(),
                    style: hud.label(size: 12, color: hud.text),
                  ),
                ),
                if (available)
                  HudToggle(
                    value: enabled.contains(g),
                    semanticLabel: 'Share ${g.label} data',
                    onChanged: (on) => _toggle(context, ref, g, on),
                  ),
              ],
            ),
            for (final type in g.types)
              _MatrixRow(
                type: type,
                state: !available
                    ? _Access.unavailable
                    : d!.granted(type)
                    ? (enabled.contains(g) ? _Access.on : _Access.paused)
                    : _Access.off,
              ),
            if (available &&
                enabled.contains(g) &&
                !d!.groupPartiallyGranted(g))
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  'Enabled here but no permission granted in Health '
                  'Connect — it may have been revoked.',
                  style: t.bodySmall?.copyWith(color: AppColors.warning),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _toggle(
    BuildContext context,
    WidgetRef ref,
    HealthGroup g,
    bool on,
  ) async {
    if (on) {
      await showHealthPermissionSheet(context, ref, g);
      return;
    }
    await ref.read(healthPermissionControllerProvider).disableGroup(g);
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            '${g.label} import turned off. To revoke the permission itself, '
            'use Health Connect settings.',
          ),
        ),
      );
    }
  }
}

enum _Access { on, paused, off, unavailable }

class _MatrixRow extends StatelessWidget {
  const _MatrixRow({required this.type, required this.state});
  final HcDataType type;
  final _Access state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final (c, glyph, word) = switch (state) {
      _Access.on => (AppColors.success, Icons.check, 'granted'),
      _Access.paused => (AppColors.warning, Icons.pause, 'granted, paused'),
      _Access.off => (hud.textMuted, Icons.close, 'not granted'),
      _Access.unavailable => (hud.textMuted, Icons.remove, 'unavailable'),
    };
    return Semantics(
      container: true,
      label: '${type.label}: $word',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: Row(
          children: [
            Expanded(child: Text(type.label, style: t.bodyMedium)),
            SizedBox(
              width: 120,
              child: Text(
                _feeds[type] ?? '',
                style: hud.mono(size: 10.5),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(
              width: 56,
              child: Align(
                alignment: Alignment.centerRight,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c.withValues(alpha: 0.12),
                    border: Border.all(color: c.withValues(alpha: 0.6)),
                    boxShadow: state == _Access.on
                        ? AppGlows.soft(c, strength: hud.glowStrength)
                        : null,
                  ),
                  child: Icon(glyph, size: 13, color: c),
                ),
              ),
            ),
          ],
        ),
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
    final hud = context.hud;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
            'you first granted access. Athlete OS imports the last 30 days '
            'either way.',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
          if (diagnostics.historyAvailable &&
              !diagnostics.historyAuthorized) ...[
            const SizedBox(height: AppSpacing.sm),
            HudButton.ghost(
              label: 'Request history access',
              compact: true,
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
            ),
          ],
        ],
      ),
    );
  }
}

class _Troubleshooting extends StatelessWidget {
  const _Troubleshooting();

  static const _items = [
    (
      'Steps are missing or look low',
      'Check that your step-counting app (e.g. Google Fit or Samsung '
          'Health) has Health Connect sync on and permission to write Steps. '
          'In Health Connect › Data and access › Steps, put that app at the '
          'top of the priority list. Then sync again.',
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
      'No heart rate or sleep',
      'A phone on its own can\'t measure heart rate and rarely records '
          'sleep. These fill in again once a watch or strap writes to Health '
          'Connect.',
    ),
    (
      'The same run appears twice',
      'Runs imported from Health Connect are keyed by their Health Connect '
          'id, so re-syncing never duplicates them. A run also imported from '
          'Strava is merged on the Running screen.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: Column(
          children: [
            for (final (q, a) in _items)
              ExpansionTile(
                title: Text(q, style: Theme.of(context).textTheme.titleSmall),
                iconColor: context.hud.accent,
                collapsedIconColor: context.hud.textMuted,
                onExpansionChanged: (_) => Haptics.selection(),
                childrenPadding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                children: [
                  Text(
                    a,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: context.hud.textMuted),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
