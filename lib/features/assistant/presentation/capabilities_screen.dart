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
      children: [
        const KillSwitchCard(),
        const SizedBox(height: AppSpacing.md),
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
    final muted = t.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(title, style: t.titleSmall)),
              if (status != null)
                StatusPill(
                  status!,
                  color: ok == null
                      ? AppColors.info
                      : (ok! ? AppColors.success : AppColors.warning),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(what),
          const SizedBox(height: AppSpacing.xs),
          Text('Why: $why', style: muted),
          const SizedBox(height: AppSpacing.xs),
          Text('Revoke: $revoke', style: muted),
          if (actionLabel != null || secondaryLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Wrap(
                spacing: AppSpacing.sm,
                children: [
                  if (actionLabel != null)
                    FilledButton.tonal(
                      onPressed: onAction,
                      child: Text(actionLabel!),
                    ),
                  if (secondaryLabel != null)
                    TextButton(
                      onPressed: onSecondary,
                      child: Text(secondaryLabel!),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
