import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../life/application/notifications/notification_providers.dart';
import '../application/providers.dart';
import 'widgets/assistant_widgets.dart';

/// Every Android permission / capability the app uses: what, why, how to
/// grant, current status and how to revoke. Each "grant" first explains,
/// then opens the system page.
class CapabilitiesScreen extends ConsumerWidget {
  const CapabilitiesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(assistantDeviceStatusProvider);
    final s = status.value;
    final platform = platformOf(ref);
    final settings = ref.watch(assistantSettingsProvider).value;

    Future<void> explainThen(
      String title,
      String body,
      Future<void> Function() go,
    ) async {
      final ok = await explainBeforeSettings(context, title: title, body: body);
      if (!ok) return;
      await go();
      ref.invalidate(assistantDeviceStatusProvider);
    }

    return AppPage(
      title: 'Permissions & capabilities',
      subtitle:
          'What the app can do on this phone, why, and how to turn it '
          'off.',
      onRefresh: () async => ref.invalidate(assistantDeviceStatusProvider),
      eyebrow: 'SYSTEMS · STATUS MATRIX',
      children: [
        const KillSwitchCard(),
        const SizedBox(height: AppSpacing.md),
        _StatusMatrix(
          loading: status.isLoading,
          cells: [
            ('Notification access', s?.listenerEnabled),
            ('Reply actions', s?.listenerConnected),
            ('Post notifications', s?.notificationsEnabled),
            ('Exact alarms', s?.exactAlarms),
            ('Battery exempt', s?.batteryUnrestricted),
            ('Keep-alive service', s?.serviceRunning),
          ],
          onRun: () {
            Haptics.medium();
            ref.invalidate(assistantDeviceStatusProvider);
          },
        ),
        const SectionHeader('Details'),
        ...spaced([
          _CapabilityCard(
            icon: Icons.notifications_active_outlined,
            title: 'Notification access',
            status: s == null
                ? null
                : (s.listenerEnabled
                      ? (s.listenerConnected ? 'On · connected' : 'On')
                      : 'Off'),
            ok: s?.listenerEnabled,
            what:
                'Lets the assistant read notifications from the messaging '
                'apps you enable (all off by default).',
            why:
                'To capture incoming messages for summaries and reply '
                'drafts. Other apps are ignored immediately and never stored.',
            revoke:
                'Settings › Notifications › Device & app notifications '
                '(Notification access) › Athlete OS assistant › off. Or use '
                'Emergency stop above.',
            actionLabel: s?.listenerEnabled ?? false
                ? 'Manage'
                : 'Grant access',
            onAction: () => requestNotificationAccess(context, ref),
          ),
          _CapabilityCard(
            icon: Icons.reply,
            title: 'Notification reply actions',
            status: s == null
                ? null
                : (s.listenerConnected ? 'Available' : 'Needs access'),
            ok: s?.listenerConnected,
            what:
                "Sends a reply through a notification's own Reply button "
                '(RemoteInput) — the same mechanism smartwatches use.',
            why:
                'Only when you tap Send on a specific draft (or, for SMS apps '
                'you allow, restricted auto-reply). Never for WhatsApp '
                'automatically. The app does not confirm delivery, so the '
                'status is "handed off", not "delivered".',
            revoke:
                'Turn off notification access or the app in Assistant '
                'settings.',
          ),
          _CapabilityCard(
            icon: Icons.notifications_outlined,
            title: 'Post notifications',
            status: s?.notificationsEnabled == null
                ? null
                : (s!.notificationsEnabled! ? 'Allowed' : 'Off'),
            ok: s?.notificationsEnabled,
            what: 'Reminders, briefings, approval prompts, Assistant mode.',
            why: 'Android 13 requires permission to show any notification.',
            revoke: 'App info › Notifications.',
            actionLabel: 'Allow',
            onAction: () => explainThen(
              'Allow notifications?',
              'Athlete OS shows only the reminders, briefings and approval '
                  'prompts you switch on. Android will ask next.',
              () async {
                final granted = await ref
                    .read(notificationGatewayProvider)
                    .requestPermission();
                if (!granted) await platform.openNotificationSettings();
              },
            ),
          ),
          _CapabilityCard(
            icon: Icons.alarm,
            title: 'Exact alarms',
            status: s?.exactAlarms == null
                ? null
                : (s!.exactAlarms! ? 'Allowed' : 'Not allowed'),
            ok: s?.exactAlarms,
            what: 'Fires reminders at the exact minute you chose.',
            why: 'Without it Android may delay reminders by several minutes.',
            revoke:
                'Settings › Apps › Special app access › Alarms & '
                'reminders.',
            actionLabel: 'Allow',
            onAction: () => explainThen(
              'Allow exact alarms?',
              'Lets reminders fire on time. Android opens "Alarms & '
                  'reminders" next.',
              () async {
                await ref
                    .read(notificationGatewayProvider)
                    .requestExactAlarms();
              },
            ),
          ),
          _CapabilityCard(
            icon: Icons.favorite_outline,
            title: 'Health Connect',
            what: 'Reads steps, workouts, sleep, heart rate and weight.',
            why: 'For your dashboards and briefings. Read-only.',
            revoke: 'Health Connect › App permissions › Athlete OS.',
            actionLabel: 'Open Health Connect',
            onAction: () => explainThen(
              'Open Health Connect?',
              'Health Connect manages which health data Athlete OS may read. '
                  'You can change or revoke access there any time.',
              () async {
                await platform.openHealthConnectSettings();
              },
            ),
            secondaryLabel: 'Status',
            onSecondary: () => context.push(AppPaths.healthStatus),
          ),
          _CapabilityCard(
            icon: Icons.battery_saver_outlined,
            title: 'Battery optimization',
            status: s == null
                ? null
                : (s.batteryUnrestricted ? 'Unrestricted' : 'Optimised'),
            ok: s?.batteryUnrestricted,
            what:
                'Exempts the app from battery optimisation so the assistant '
                'keeps running on an always-on phone.',
            why:
                'ColorOS (OPPO) aggressively stops background apps. Also do: '
                'Settings › Battery › App battery management › Athlete OS › '
                'Allow background activity + Allow auto launch; and lock the '
                'app in Recents (drag down on its card / tap the lock).',
            revoke:
                'Settings › Battery › App battery management › Athlete OS '
                '› Optimise.',
            actionLabel: 'Request exemption',
            onAction: () => explainThen(
              'Stop battery optimisation?',
              'Android will ask to let Athlete OS run in the background. '
                  'This uses a little more battery. On ColorOS also allow '
                  'background activity and auto launch in App battery '
                  'management.',
              () async {
                await platform.requestIgnoreBatteryOptimizations();
              },
            ),
            secondaryLabel: 'App info',
            onSecondary: () => platform.openAppDetailsSettings(),
          ),
          _CapabilityCard(
            icon: Icons.bolt_outlined,
            title: 'Assistant foreground service',
            status: s == null ? null : (s.serviceRunning ? 'Running' : 'Off'),
            ok: s?.serviceRunning,
            what:
                'Optional "Assistant mode": a low-priority persistent '
                'notification that keeps the app process alive.',
            why:
                'So capture and processing continue while the phone sits '
                'on a desk. ColorOS may still stop it without the battery '
                'steps above.',
            revoke: 'Tap Stop on its notification, or turn it off here.',
            actionLabel: s?.serviceRunning ?? false ? 'Stop' : 'Start',
            onAction: (settings?.killSwitch ?? false)
                ? null
                : () async {
                    await ref
                        .read(assistantControllerProvider)
                        .setServiceEnabled(!(s?.serviceRunning ?? false));
                    ref.invalidate(assistantDeviceStatusProvider);
                  },
          ),
          _CapabilityCard(
            icon: Icons.photo_camera_outlined,
            title: 'Camera',
            what: 'Barcode scanning and meal photos.',
            why: 'Asked the first time you scan; never used in background.',
            revoke: 'App info › Permissions › Camera.',
            actionLabel: 'App info',
            onAction: () => platform.openAppDetailsSettings(),
          ),
          const _CapabilityCard(
            icon: Icons.share_outlined,
            title: 'Share sheet',
            status: 'Available',
            ok: true,
            what:
                'Share any text (e.g. a message) into Athlete OS: draft a '
                'reply, log food from text, or ask the coach.',
            why: 'A manual, explicit way to bring content in. No permission.',
            revoke: 'Nothing to revoke — only what you share is received.',
          ),
          const _CapabilityCard(
            icon: Icons.open_in_new,
            title: 'Open other apps',
            status: 'Available',
            ok: true,
            what:
                'Lists launchable apps (for per-app settings) and opens an '
                'app for "Copy & open".',
            why: 'Android 11+ package visibility; limited to launcher apps.',
            revoke: 'Not a runtime permission.',
          ),
          const _CapabilityCard(
            icon: Icons.accessibility_new,
            title: 'Accessibility service — NOT used',
            status: 'Not used',
            ok: true,
            what:
                'Athlete OS does not use an accessibility service, screen '
                'reading or UI automation.',
            why:
                "Android's accessibility policy requires a genuine "
                'accessibility use case; automating other apps is not one. It '
                'would also be able to read everything on screen. Notification '
                'access + reply actions are the narrower, policy-compliant '
                'mechanism.',
            revoke: '—',
          ),
        ]),
      ],
    );
  }
}

/// Live checks as a grid of LEDs: green = ready, amber = needs action,
/// dim = unknown on this device.
class _StatusMatrix extends StatelessWidget {
  const _StatusMatrix({
    required this.cells,
    required this.loading,
    required this.onRun,
  });

  final List<(String, bool?)> cells;
  final bool loading;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final ready = cells.where((c) => c.$2 == true).length;
    return HudFrame(
      tag: 'LIVE·CHECKS',
      inset: -3,
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AnimatedTicker(
                  '$ready/${cells.length}',
                  style: hud.number(size: 30),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text('SUBSYSTEMS READY', style: hud.label(size: 11.5)),
                ),
                HudButton.secondary(
                  label: loading ? 'Scanning' : 'Run checks',
                  icon: Icons.radar_rounded,
                  compact: true,
                  loading: loading,
                  onPressed: loading ? null : onRun,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (loading)
              const ScanlineLoader(height: 96, lines: 0)
            else
              LayoutBuilder(
                builder: (context, box) {
                  final w = (box.maxWidth - AppSpacing.sm) / 2;
                  return Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      for (var i = 0; i < cells.length; i++)
                        SizedBox(
                          width: w,
                          child: Entrance(
                            delay: Duration(milliseconds: 40 * i),
                            child: _Led(label: cells[i].$1, ok: cells[i].$2),
                          ),
                        ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _Led extends StatelessWidget {
  const _Led({required this.label, required this.ok});
  final String label;
  final bool? ok;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final c = ok == null
        ? hud.textMuted
        : ok!
        ? AppColors.success
        : AppColors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.sm),
        color: c.withValues(alpha: ok == null ? 0.04 : 0.08),
        border: Border.all(color: c.withValues(alpha: ok == null ? 0.15 : 0.4)),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c,
              boxShadow: ok == null
                  ? null
                  : [
                      BoxShadow(
                        color: c.withValues(alpha: 0.8 * hud.glowStrength),
                        blurRadius: 6,
                      ),
                    ],
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: hud.label(
                size: 10,
                color: hud.text.withValues(alpha: 0.85),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({
    required this.icon,
    required this.title,
    required this.what,
    required this.why,
    required this.revoke,
    this.status,
    this.ok,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String what;
  final String why;
  final String revoke;
  final String? status;
  final bool? ok;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = HudTheme.of(context);
    final muted = t.bodySmall?.copyWith(color: hud.textMuted, height: 1.4);
    final c = ok == null
        ? AppColors.info
        : (ok! ? AppColors.success : AppColors.warning);
    Widget labelled(String label, String text) => Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 64, child: Text(label, style: hud.label(size: 10.5))),
          Expanded(child: Text(text, style: muted)),
        ],
      ),
    );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GlowIcon(icon, size: 18, framed: true, color: c),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: Text(title, style: t.titleSmall)),
              if (status != null) StatusPill(status!, color: c),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(what, style: t.bodyMedium),
          labelled('WHY', why),
          labelled('REVOKE', revoke),
          if (actionLabel != null || secondaryLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  if (actionLabel != null)
                    HudButton.secondary(
                      label: actionLabel!,
                      compact: true,
                      onPressed: onAction,
                    ),
                  if (secondaryLabel != null)
                    HudButton.ghost(
                      label: secondaryLabel!,
                      compact: true,
                      onPressed: onSecondary,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
