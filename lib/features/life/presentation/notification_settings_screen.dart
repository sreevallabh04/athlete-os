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
import 'widgets/quiet_hours_dial.dart';

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
    final ok = await confirmHud(
      context,
      icon: Icons.notifications_active_outlined,
      title: 'Allow notifications?',
      message:
          'Athlete OS only sends the reminders you switch on here, at the '
          'times you choose. Android will ask for permission next. You can '
          'change this any time in system settings.',
      cancelLabel: 'Not now',
      confirmLabel: 'Continue',
    );
    if (!ok) return false;
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
    Haptics.success();
    setState(() {
      _rescheduling = false;
      _result = r ?? _result;
    });
  }

  Future<void> _sendTest() async {
    final ok = await _ensurePermission();
    if (!ok) return;
    await ref.read(reminderServiceProvider).sendTest();
    Haptics.success();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Test notification sent.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final prefs = ref.watch(notificationPrefsProvider);
    final perm = ref.watch(notificationPermissionProvider).value;
    final quiet = ref.watch(quietHoursProvider).value;
    final calendarAware =
        ref.watch(calendarAwareRemindersProvider).value ?? false;
    final profile = ref.watch(profileProvider).value;
    final settings = ref.read(settingsRepositoryProvider);
    final wake = profile?.wakeMinutes ?? 390;
    final sleep = profile?.sleepMinutes ?? 1350;
    final enabledCount = prefs.value?.values.where((p) => p.enabled).length;

    return AppPage(
      title: 'Notifications',
      eyebrow: 'REMINDERS · ON-DEVICE SCHEDULER',
      subtitle:
          'Every reminder is off until you turn it on. Reminders are '
          'scheduled on this phone — there is no server push.',
      children: [
        const SizedBox(height: AppSpacing.sm),
        if (perm?.enabled == false) ...[
          NoticeBanner(
            icon: Icons.notifications_off_outlined,
            color: AppColors.warning,
            message:
                'Notifications are turned off for Athlete OS, so reminders '
                'won\'t appear.',
            actionLabel: 'Allow',
            onAction: _ensurePermission,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        _StatusCard(
          enabledCount: enabledCount,
          total: ReminderKind.values.length,
          result: _result,
          rescheduling: _rescheduling,
          onTest: _sendTest,
          onReschedule: _reschedule,
        ),
        ...prefs.when(
          loading: () => const [
            SizedBox(height: AppSpacing.xl),
            ScanlineLoader(lines: 4),
          ],
          error: (e, _) => [
            ErrorState(
              message: 'Reminder settings couldn\'t be loaded.',
              onRetry: () => ref.invalidate(notificationPrefsProvider),
            ),
          ],
          data: (p) => [
            for (final ch in ReminderChannel.values) ...[
              if (ReminderKind.values.any((k) => k.channel == ch)) ...[
                SectionHeader(ch.label),
                ...spaced([
                  for (final kind in ReminderKind.values)
                    if (kind.channel == ch)
                      _KindCard(
                        pref: p[kind]!,
                        wakeMinutes: wake,
                        sleepMinutes: sleep,
                        onEnabled: (v) => _save(kind, enabled: v),
                        onConfig: (c) => _save(kind, config: c),
                      ),
                ], gap: AppSpacing.sm),
              ],
            ],
          ],
        ),
        const LifeSection(
          'Quiet hours',
          hint: 'No reminder of any kind is scheduled in this window',
        ),
        AppCard(
          accent: quiet == null ? null : hud.accent,
          child: Column(
            children: [
              HudRow(
                leading: GlowIcon(
                  Icons.bedtime_outlined,
                  size: 20,
                  color: quiet == null
                      ? hud.textMuted
                      : const Color(0xFF8F94FF),
                  glow: quiet == null ? 0 : 1,
                ),
                title: 'Quiet hours',
                subtitle: quiet == null
                    ? 'Off'
                    : '${formatMinutes(quiet.start)} – '
                          '${formatMinutes(quiet.end)}'
                          '${quiet.isOvernight ? ' (overnight)' : ''}',
                trailing: HudToggle(
                  key: const Key('quiet-hours'),
                  value: quiet != null,
                  semanticLabel: 'Quiet hours',
                  onChanged: (on) => settings.set(
                    SettingKeys.quietHours,
                    on
                        ? QuietHours(
                            (sleep - 30) % 1440 ~/ 15 * 15,
                            wake ~/ 15 * 15,
                          ).toJson()
                        : null,
                  ),
                ),
              ),
              AnimatedSize(
                duration: AppMotion.medium,
                curve: AppMotion.standard,
                alignment: Alignment.topCenter,
                child: quiet == null
                    ? const SizedBox(width: double.infinity)
                    : Column(
                        children: [
                          const SizedBox(height: AppSpacing.md),
                          LayoutBuilder(
                            builder: (context, box) => QuietHoursDial(
                              size: box.maxWidth.clamp(200.0, 280.0),
                              start: quiet.start,
                              end: quiet.end,
                              wakeMinutes: wake,
                              sleepMinutes: sleep,
                              onChanged: (s, e) => settings.set(
                                SettingKeys.quietHours,
                                QuietHours(s, e).toJson(),
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: AppSpacing.md,
                            runSpacing: AppSpacing.sm,
                            children: [
                              HudTimeChip(
                                label: 'FROM',
                                minutes: quiet.start,
                                onChanged: (m) {
                                  if (m == quiet.end) return;
                                  settings.set(
                                    SettingKeys.quietHours,
                                    QuietHours(m, quiet.end).toJson(),
                                  );
                                },
                              ),
                              HudTimeChip(
                                label: 'UNTIL',
                                minutes: quiet.end,
                                onChanged: (m) {
                                  if (m == quiet.start) return;
                                  settings.set(
                                    SettingKeys.quietHours,
                                    QuietHours(quiet.start, m).toJson(),
                                  );
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: AppSpacing.md,
                            children: [
                              _Legend(
                                color: AppColors.gold,
                                label: 'WAKE ${formatMinutes(wake)}',
                              ),
                              _Legend(
                                color: const Color(0xFF8F94FF),
                                label: 'SLEEP ${formatMinutes(sleep)}',
                              ),
                            ],
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        const SectionHeader('Calendar timing'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HudRow(
                leading: GlowIcon(
                  Icons.event_busy_outlined,
                  size: 20,
                  color: calendarAware ? hud.accent : hud.textMuted,
                  glow: calendarAware ? 1 : 0,
                ),
                title: 'Avoid busy calendar events',
                subtitle:
                    'Water reminders during a busy event are dropped; other '
                    'reminders move to the end of the event (up to 3 hours).',
                trailing: HudToggle(
                  value: calendarAware,
                  semanticLabel: 'Avoid busy calendar events',
                  onChanged: (v) =>
                      settings.set(SettingKeys.calendarAwareReminders, v),
                ),
              ),
              if (calendarAware &&
                  _result?.calendar == CalendarAwareness.notConnected) ...[
                const SizedBox(height: AppSpacing.md),
                const NoticeBanner(
                  message:
                      'Google Calendar isn\'t connected, so reminders use '
                      'your normal schedule.',
                ),
              ],
              if (calendarAware &&
                  _result?.calendar == CalendarAwareness.failed) ...[
                const SizedBox(height: AppSpacing.md),
                const NoticeBanner(
                  color: AppColors.warning,
                  message:
                      'Calendar events couldn\'t be read last time; '
                      'reminders used your normal schedule.',
                ),
              ],
            ],
          ),
        ),
        const SectionHeader('Reliability on Android'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HudRow(
                leading: GlowIcon(
                  perm?.exactAllowed == true
                      ? Icons.timer_outlined
                      : Icons.timelapse_outlined,
                  size: 20,
                  color: perm?.exactAllowed == true
                      ? AppColors.success
                      : hud.textMuted,
                  glow: perm?.exactAllowed == true ? 1 : 0,
                ),
                title: perm?.exactAllowed == true
                    ? 'Precise timing is allowed.'
                    : perm?.exactAllowed == false
                    ? 'Precise timing is off'
                    : 'Alarm timing status unavailable on this device.',
                subtitle: perm?.exactAllowed == false
                    ? 'Reminders may arrive a few minutes late.'
                    : null,
              ),
              if (perm?.exactAllowed == false) ...[
                const SizedBox(height: AppSpacing.sm),
                HudButton.secondary(
                  label: 'Allow precise timing (optional)',
                  compact: true,
                  onPressed: () async {
                    await ref
                        .read(notificationGatewayProvider)
                        .requestExactAlarms();
                    ref.invalidate(notificationPermissionProvider);
                  },
                ),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                child: Divider(
                  height: 1,
                  color: hud.hairline.withValues(alpha: 0.12),
                ),
              ),
              Row(
                children: [
                  const GlowIcon(
                    Icons.battery_saver_outlined,
                    size: 18,
                    color: AppColors.warning,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text('Keep reminders on time', style: t.titleSmall),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Battery savers can delay or silence reminders while the phone '
                'is idle (Doze). Two minutes here makes them dependable.',
                style: t.bodySmall?.copyWith(color: hud.textMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              const _GuideBlock(
                tag: 'OPPO · COLOROS',
                steps: [
                  'Settings › Battery › App battery management › Athlete OS',
                  'Turn on "Allow background activity" and "Allow auto-launch"',
                  'Open Recents and lock the Athlete OS card (open its menu or '
                      'pull it down, then Lock)',
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              const _GuideBlock(
                tag: 'SAMSUNG · ONE UI',
                steps: [
                  'Settings › Battery › Background usage limits: make sure '
                      'Athlete OS is not in "Sleeping" or "Deep sleeping" apps',
                  'Settings › Apps › Athlete OS › Battery › Unrestricted',
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Reminders are planned for the next 7 days and re-planned '
                'each time you open the app, so open it at least once a '
                'week. Force-stopping the app cancels pending reminders '
                'until you open it again.',
                style: t.bodySmall?.copyWith(color: hud.textMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              HudButton.secondary(
                label: 'Open notification settings',
                icon: Icons.open_in_new,
                compact: true,
                onPressed: () =>
                    ref.read(notificationGatewayProvider).openSystemSettings(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Text(label, style: context.hud.mono(size: 10.5)),
    ],
  );
}

class _GuideBlock extends StatelessWidget {
  const _GuideBlock({required this.tag, required this.steps});
  final String tag;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return GlassPanel(
      padding: const EdgeInsets.all(AppSpacing.md),
      radius: AppRadii.md,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tag, style: hud.label(size: 11, color: hud.accentInk)),
          const SizedBox(height: AppSpacing.sm),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: EdgeInsets.only(
                bottom: i == steps.length - 1 ? 0 : AppSpacing.sm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    margin: const EdgeInsets.only(right: AppSpacing.sm),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: hud.accent.withValues(alpha: 0.45),
                      ),
                    ),
                    child: Text(
                      '${i + 1}',
                      style: hud.mono(size: 10, color: hud.accentInk),
                    ),
                  ),
                  Expanded(child: Text(steps[i], style: t.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.enabledCount,
    required this.total,
    required this.result,
    required this.rescheduling,
    required this.onTest,
    required this.onReschedule,
  });
  final int? enabledCount;
  final int total;
  final RescheduleResult? result;
  final bool rescheduling;
  final VoidCallback onTest;
  final VoidCallback onReschedule;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final n = enabledCount ?? 0;
    return AppCard(
      brackets: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProgressRing(
                progress: total == 0 ? 0 : n / total,
                color: hud.accent,
                size: 64,
                stroke: 6,
                celebrate: false,
                center: AnimatedTicker('$n', style: hud.number(size: 24)),
                semanticLabel: '$n of $total reminders on',
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('REMINDERS ON', style: hud.label(size: 11)),
                    const SizedBox(height: 2),
                    Text(
                      n == 0 ? 'All quiet' : '$n of $total kinds active',
                      style: t.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      result == null
                          ? 'Re-planned automatically when settings change'
                          : '${result!.scheduled} PLANNED · NEXT 7 DAYS · '
                                '${result!.exact ? 'PRECISE' : 'APPROX'}',
                      style: hud.mono(size: 10.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: HudButton.secondary(
                  label: 'Send test',
                  icon: Icons.notifications_active_outlined,
                  compact: true,
                  onPressed: onTest,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: HudButton.ghost(
                  label: 'Re-plan now',
                  icon: Icons.refresh,
                  compact: true,
                  loading: rescheduling,
                  onPressed: rescheduling ? null : onReschedule,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

IconData _kindIcon(ReminderKind k) => switch (k) {
  ReminderKind.water => Icons.water_drop_outlined,
  ReminderKind.habit => Icons.task_alt,
  ReminderKind.planning => Icons.event_note_outlined,
  ReminderKind.mood => Icons.mood_outlined,
  ReminderKind.journal => Icons.menu_book_outlined,
  ReminderKind.meal => Icons.restaurant_outlined,
  ReminderKind.eodReview => Icons.nights_stay_outlined,
  ReminderKind.weeklySummary => Icons.insights_outlined,
  ReminderKind.workout => Icons.fitness_center,
  ReminderKind.steps => Icons.directions_walk,
  ReminderKind.competition => Icons.emoji_events_outlined,
  ReminderKind.posing => Icons.accessibility_new,
};

/// Metric family colour where the reminder belongs to one; null = accent.
Color? _kindColor(ReminderKind k) => switch (k) {
  ReminderKind.water => AppColors.water,
  ReminderKind.habit => AppColors.habit,
  ReminderKind.mood => AppColors.mood,
  ReminderKind.meal => AppColors.calories,
  ReminderKind.workout => AppColors.strength,
  ReminderKind.steps => AppColors.steps,
  ReminderKind.competition || ReminderKind.posing => AppColors.competition,
  _ => null,
};

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
    final hud = context.hud;
    final kind = pref.kind;
    final c = pref.config;
    final color = _kindColor(kind) ?? hud.accent;
    final time = c.times.isNotEmpty
        ? c.times.first
        : kind.defaults.times.isNotEmpty
        ? kind.defaults.times.first
        : 9 * 60;

    Widget config() => switch (kind.shape) {
      ConfigShape.interval => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('EVERY', style: hud.label(size: 11)),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final m in const [60, 90, 120, 180, 240])
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40),
                  child: HudChip(
                    label: m % 60 == 0 ? '${m ~/ 60} h' : '${m / 60} h',
                    uppercase: false,
                    color: color,
                    selected: c.intervalMinutes == m,
                    onTap: () => onConfig(c.copyWith(intervalMinutes: m)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          HudStepper(
            label: 'At most per day',
            value: c.maxPerDay,
            min: 1,
            max: 16,
            unit: 'MAX PER DAY',
            color: color,
            decreaseTooltip: 'Fewer per day',
            increaseTooltip: 'More per day',
            onChanged: (v) => onConfig(c.copyWith(maxPerDay: v)),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Only between waking (${formatMinutes(wakeMinutes)}) and sleep '
            '(${formatMinutes(sleepMinutes)}) from your profile.',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
        ],
      ),
      ConfigShape.timeAndDays => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HudTimeChip(
            label: 'AT',
            minutes: time,
            color: color,
            onChanged: (m) => onConfig(c.copyWith(times: [m])),
          ),
          const SizedBox(height: AppSpacing.md),
          WeekdayPicker(
            mask: c.daysMask,
            color: color,
            onChanged: (m) => onConfig(c.copyWith(daysMask: m)),
          ),
        ],
      ),
      ConfigShape.timesAndDays => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TimesEditor(
            times: c.times,
            color: color,
            onChanged: (v) => onConfig(c.copyWith(times: v)),
          ),
          const SizedBox(height: AppSpacing.md),
          WeekdayPicker(
            mask: c.daysMask,
            color: color,
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
            color: color,
            onChanged: (m) => onConfig(c.copyWith(daysMask: m)),
          ),
          const SizedBox(height: AppSpacing.md),
          HudTimeChip(
            label: 'AT',
            minutes: time,
            color: color,
            onChanged: (m) => onConfig(c.copyWith(times: [m])),
          ),
        ],
      ),
      ConfigShape.timeOnly => HudTimeChip(
        label: 'MORNING OF, AT',
        minutes: time,
        color: color,
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
          HudButton.ghost(
            label: 'Habits',
            compact: true,
            icon: Icons.east,
            onPressed: () => context.push(AppPaths.habits),
          ),
        ],
      ),
    };

    return AppCard(
      accent: pref.enabled ? color : null,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HudRow(
            leading: GlowIcon(
              _kindIcon(kind),
              size: 20,
              color: pref.enabled ? color : hud.textMuted,
              glow: pref.enabled ? 1 : 0,
            ),
            title: kind.label,
            subtitle: kind.description,
            trailing: HudToggle(
              key: Key('reminder-${kind.key}'),
              value: pref.enabled,
              color: color,
              semanticLabel: kind.label,
              onChanged: onEnabled,
            ),
          ),
          AnimatedSize(
            duration: AppMotion.medium,
            curve: AppMotion.standard,
            alignment: Alignment.topCenter,
            child: pref.enabled
                ? Padding(
                    padding: const EdgeInsets.only(
                      top: AppSpacing.md,
                      right: AppSpacing.sm,
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
