import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../../data/repositories/settings_repository.dart';
import '../application/notifications/notification_providers.dart';
import '../application/notifications/reminder_service.dart';
import '../data/notification_prefs_repository.dart';
import '../domain/habit_models.dart';
import '../domain/reminder_kinds.dart';
import '../domain/reminder_scheduler.dart';
import 'widgets/life_widgets.dart';

class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  ConsumerState<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends ConsumerState<NotificationSettingsScreen> {
  RescheduleResult? _result;
  bool _rescheduling = false;

  @override
  void initState() {
    super.initState();
    _result = ref.read(reminderServiceProvider).lastResult;
  }

  /// Explains why before showing the Android permission prompt.
  Future<bool> _ensurePermission() async {
    final g = ref.read(notificationGatewayProvider);
    final enabled = await g.notificationsEnabled();
    if (enabled != false || !mounted) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.notifications_active_outlined),
        title: const Text('Allow notifications?'),
        content: const Text(
          'Athlete OS only sends the reminders you switch on here, at the '
          'times you choose. Android will ask for permission next. You can '
          'change this any time in system settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    final granted = await g.requestPermission();
    ref.invalidate(notificationPermissionProvider);
    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Notifications are still off. You can allow them in system '
            'settings.',
          ),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () => g.openSystemSettings(),
          ),
        ),
      );
    }
    return granted;
  }

  Future<void> _save(
    ReminderKind kind, {
    bool? enabled,
    ReminderConfig? config,
  }) async {
    if (enabled == true) await _ensurePermission();
    await ref
        .read(notificationPrefsRepositoryProvider)
        .save(kind, enabled: enabled, config: config);
  }

  Future<void> _reschedule() async {
    setState(() => _rescheduling = true);
    final r = await ref.read(reminderServiceProvider).rescheduleAll();
    if (!mounted) return;
    setState(() {
      _rescheduling = false;
      _result = r ?? _result;
    });
  }

  Future<void> _sendTest() async {
    final ok = await _ensurePermission();
    if (!ok) return;
    await ref.read(reminderServiceProvider).sendTest();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Test notification sent.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final prefs = ref.watch(notificationPrefsProvider);
    final perm = ref.watch(notificationPermissionProvider).value;
    final quiet = ref.watch(quietHoursProvider).value;
    final calendarAware =
        ref.watch(calendarAwareRemindersProvider).value ?? false;
    final profile = ref.watch(profileProvider).value;
    final settings = ref.read(settingsRepositoryProvider);

    return AppPage(
      title: 'Notifications',
      subtitle:
          'Every reminder is off until you turn it on. Reminders are '
          'scheduled on this phone — there is no server push.',
      children: [
        const SizedBox(height: AppSpacing.md),
        if (perm?.enabled == false)
          NoticeBanner(
            icon: Icons.notifications_off_outlined,
            color: AppColors.warning,
            message:
                'Notifications are turned off for Athlete OS, so reminders '
                'won\'t appear.',
            actionLabel: 'Allow',
            onAction: _ensurePermission,
          ),
        const SectionHeader('Reminders'),
        ...prefs.when(
          loading: () => const [LoadingState()],
          error: (e, _) => [
            ErrorState(
              message: 'Reminder settings couldn\'t be loaded.',
              onRetry: () => ref.invalidate(notificationPrefsProvider),
            ),
          ],
          data: (p) => spaced([
            for (final kind in ReminderKind.values)
              _KindCard(
                pref: p[kind]!,
                wakeMinutes: profile?.wakeMinutes ?? 390,
                sleepMinutes: profile?.sleepMinutes ?? 1350,
                onEnabled: (v) => _save(kind, enabled: v),
                onConfig: (c) => _save(kind, config: c),
              ),
          ], gap: AppSpacing.sm),
        ),
        const SectionHeader(
          'Quiet hours',
          subtitle: 'No reminder of any kind is scheduled in this window',
        ),
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Quiet hours'),
                subtitle: Text(
                  quiet == null
                      ? 'Off'
                      : '${formatMinutes(quiet.start)} – '
                            '${formatMinutes(quiet.end)}'
                            '${quiet.isOvernight ? ' (overnight)' : ''}',
                ),
                value: quiet != null,
                onChanged: (on) => settings.set(
                  SettingKeys.quietHours,
                  on ? const QuietHours(22 * 60, 7 * 60).toJson() : null,
                ),
              ),
              if (quiet != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    0,
                    AppSpacing.lg,
                    AppSpacing.md,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _TimeButton(
                          label: 'From',
                          minutes: quiet.start,
                          onChanged: (m) => settings.set(
                            SettingKeys.quietHours,
                            QuietHours(m, quiet.end).toJson(),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: _TimeButton(
                          label: 'Until',
                          minutes: quiet.end,
                          onChanged: (m) => settings.set(
                            SettingKeys.quietHours,
                            QuietHours(quiet.start, m).toJson(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SectionHeader('Calendar-aware timing'),
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                title: const Text('Avoid busy calendar events'),
                subtitle: const Text(
                  'Water reminders during a busy event are dropped; other '
                  'reminders move to the end of the event (up to 3 hours).',
                ),
                value: calendarAware,
                onChanged: (v) =>
                    settings.set(SettingKeys.calendarAwareReminders, v),
              ),
              if (calendarAware &&
                  _result?.calendar == CalendarAwareness.notConnected)
                const Padding(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    0,
                    AppSpacing.lg,
                    AppSpacing.md,
                  ),
                  child: NoticeBanner(
                    message:
                        'Google Calendar isn\'t connected, so reminders use '
                        'your normal schedule.',
                  ),
                ),
              if (calendarAware &&
                  _result?.calendar == CalendarAwareness.failed)
                const Padding(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    0,
                    AppSpacing.lg,
                    AppSpacing.md,
                  ),
                  child: NoticeBanner(
                    color: AppColors.warning,
                    message:
                        'Calendar events couldn\'t be read last time; '
                        'reminders used your normal schedule.',
                  ),
                ),
            ],
          ),
        ),
        const SectionHeader('Reliability on Android'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    perm?.exactAllowed == true
                        ? Icons.timer_outlined
                        : Icons.timelapse_outlined,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      perm?.exactAllowed == true
                          ? 'Precise timing is allowed.'
                          : perm?.exactAllowed == false
                          ? 'Precise timing is off: reminders may arrive a '
                                'few minutes late.'
                          : 'Alarm timing status unavailable on this device.',
                      style: t.bodyMedium,
                    ),
                  ),
                ],
              ),
              if (perm?.exactAllowed == false) ...[
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton(
                  onPressed: () async {
                    await ref
                        .read(notificationGatewayProvider)
                        .requestExactAlarms();
                    ref.invalidate(notificationPermissionProvider);
                  },
                  child: const Text('Allow precise timing (optional)'),
                ),
              ],
              const Divider(height: AppSpacing.xl),
              Text('Battery saving and Doze', style: t.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Android may delay reminders while the phone is idle (Doze) '
                'or if the app is battery-restricted. On Samsung Galaxy '
                'phones, open Settings › Battery › Background usage limits '
                'and make sure Athlete OS is not in "Sleeping apps" or "Deep '
                'sleeping apps". Then set Settings › Apps › Athlete OS › '
                'Battery to "Unrestricted".\n\n'
                'Reminders are planned for the next 7 days and re-planned '
                'each time you open the app, so open it at least once a '
                'week. Force-stopping the app cancels pending reminders '
                'until you open it again.',
                style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.md),
              OutlinedButton.icon(
                onPressed: () =>
                    ref.read(notificationGatewayProvider).openSystemSettings(),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open notification settings'),
              ),
            ],
          ),
        ),
        const SectionHeader('Check it works'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.tonalIcon(
                onPressed: _sendTest,
                icon: const Icon(Icons.notifications_active_outlined),
                label: const Text('Send test notification'),
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: _rescheduling ? null : _reschedule,
                icon: const Icon(Icons.refresh),
                label: const Text('Re-plan reminders now'),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                _result == null
                    ? 'Reminders are re-planned automatically when you change '
                          'these settings or your habits.'
                    : '${_result!.scheduled} reminders planned for the next '
                          '7 days (${_result!.exact ? 'precise' : 'approximate'} '
                          'timing).',
                style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TimeButton extends StatelessWidget {
  const _TimeButton({
    required this.label,
    required this.minutes,
    required this.onChanged,
  });
  final String label;
  final int minutes;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: () async {
      final m = await pickMinutes(context, minutes);
      if (m != null) onChanged(m);
    },
    child: Text('$label ${formatMinutes(minutes)}'),
  );
}

class _KindCard extends StatelessWidget {
  const _KindCard({
    required this.pref,
    required this.wakeMinutes,
    required this.sleepMinutes,
    required this.onEnabled,
    required this.onConfig,
  });

  final ReminderPref pref;
  final int wakeMinutes;
  final int sleepMinutes;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<ReminderConfig> onConfig;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final kind = pref.kind;
    final c = pref.config;
    final time = c.times.isNotEmpty
        ? c.times.first
        : kind.defaults.times.isNotEmpty
        ? kind.defaults.times.first
        : 9 * 60;

    Widget config() => switch (kind.shape) {
      ConfigShape.interval => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Every', style: t.labelLarge),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final m in const [60, 90, 120, 180, 240])
                ChoiceChip(
                  label: Text(m % 60 == 0 ? '${m ~/ 60} h' : '${m / 60} h'),
                  selected: c.intervalMinutes == m,
                  onSelected: (_) => onConfig(c.copyWith(intervalMinutes: m)),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Text(
                  'At most ${c.maxPerDay} per day',
                  style: t.bodyMedium,
                ),
              ),
              IconButton(
                tooltip: 'Fewer per day',
                onPressed: c.maxPerDay > 1
                    ? () => onConfig(c.copyWith(maxPerDay: c.maxPerDay - 1))
                    : null,
                icon: const Icon(Icons.remove),
              ),
              IconButton(
                tooltip: 'More per day',
                onPressed: c.maxPerDay < 16
                    ? () => onConfig(c.copyWith(maxPerDay: c.maxPerDay + 1))
                    : null,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          Text(
            'Only between waking (${formatMinutes(wakeMinutes)}) and sleep '
            '(${formatMinutes(sleepMinutes)}) from your profile.',
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      ConfigShape.timeAndDays => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TimeButton(
            label: 'At',
            minutes: time,
            onChanged: (m) => onConfig(c.copyWith(times: [m])),
          ),
          const SizedBox(height: AppSpacing.sm),
          WeekdayPicker(
            mask: c.daysMask,
            onChanged: (m) => onConfig(c.copyWith(daysMask: m)),
          ),
        ],
      ),
      ConfigShape.timesAndDays => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TimesEditor(
            times: c.times,
            onChanged: (v) => onConfig(c.copyWith(times: v)),
          ),
          const SizedBox(height: AppSpacing.sm),
          WeekdayPicker(
            mask: c.daysMask,
            onChanged: (m) => onConfig(c.copyWith(daysMask: m)),
          ),
        ],
      ),
      ConfigShape.weekly => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          WeekdayPicker(
            single: true,
            mask: c.daysMask,
            onChanged: (m) => onConfig(c.copyWith(daysMask: m)),
          ),
          const SizedBox(height: AppSpacing.sm),
          _TimeButton(
            label: 'At',
            minutes: time,
            onChanged: (m) => onConfig(c.copyWith(times: [m])),
          ),
        ],
      ),
      ConfigShape.timeOnly => _TimeButton(
        label: 'Morning of, at',
        minutes: time,
        onChanged: (m) => onConfig(c.copyWith(times: [m])),
      ),
      ConfigShape.perItem => Row(
        children: [
          Expanded(
            child: Text(
              'Set reminder times on each habit.',
              style: t.bodyMedium,
            ),
          ),
          TextButton(
            onPressed: () => context.push(AppPaths.habits),
            child: const Text('Habits'),
          ),
        ],
      ),
    };

    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            key: Key('reminder-${kind.key}'),
            title: Text(kind.label),
            subtitle: Text(kind.description),
            value: pref.enabled,
            onChanged: onEnabled,
          ),
          AnimatedSize(
            duration: AppDurations.medium,
            curve: Curves.easeOutCubic,
            child: pref.enabled
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      0,
                      AppSpacing.lg,
                      AppSpacing.md,
                    ),
                    child: config(),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
