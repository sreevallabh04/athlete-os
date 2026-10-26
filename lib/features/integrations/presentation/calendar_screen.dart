import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/paths.dart';
import '../../../core/config/env.dart';
import '../../../core/contracts/calendar_reader.dart';
import '../../../core/domain/free_slots.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../onboarding/application/persona_providers.dart';
import '../../onboarding/domain/daily_routine.dart';
import '../../train/application/train_providers.dart';
import '../../train/presentation/widgets/hud_kit.dart';
import '../data/api_errors.dart';
import '../data/google_calendar_service.dart';
import '../domain/slot_suggestions.dart';

/// Whether this build has Google OAuth credentials. A provider (not a direct
/// `Env` read) so previews and tests can render the connected agenda.
final calendarConfiguredProvider = Provider<bool>((ref) => Env.hasGoogle);

enum _View { day, week }

/// Calendar: a HUD day timeline (events as glass blocks, free time as
/// dashed cyan slots you can tap to plan into) and a week capacity view.
/// Without Google it still shows today's JARVIS routine as a timeline.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  _View _view = _View.day;
  late String _day;
  Future<List<CalendarEventView>>? _future;

  @override
  void initState() {
    super.initState();
    _day = LocalDates.key(ref.read(clockProvider).now());
  }

  (DateTime, DateTime) get _range {
    if (_view == _View.day) return LocalDates.bounds(_day);
    final ws = LocalDates.weekStart(_day);
    return (
      LocalDates.bounds(ws).$1,
      LocalDates.bounds(LocalDates.addDays(ws, 6)).$2,
    );
  }

  void _load() {
    final (s, e) = _range;
    setState(() {
      _future = ref.read(googleCalendarServiceProvider).eventsBetween(s, e);
    });
  }

  void _shift(int dir) {
    Haptics.selection();
    setState(() {
      _day = LocalDates.addDays(_day, dir * (_view == _View.day ? 1 : 7));
    });
    _load();
  }

  Future<void> _plan({TimeInterval? slot}) async {
    final created = await showHudBottomSheet<bool>(
      context,
      title: 'Plan a block',
      builder: (_) => _PlanBlockSheet(initialDay: _day, initialSlot: slot),
    );
    if (created == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final configured = ref.watch(calendarConfiguredProvider);
    final row = ref
        .watch(integrationStatusProvider(Providers.googleCalendar))
        .value;
    final now = ref.watch(clockProvider).now();
    final profile = ref.watch(profileProvider).value;
    final wake = profile?.wakeMinutes ?? 390;
    final sleep = profile?.sleepMinutes ?? 1350;
    if (!configured || !isConnected(row)) {
      return _OfflineCalendar(
        configured: configured,
        row: row,
        now: now,
        wake: wake,
        sleep: sleep,
      );
    }
    _future ??= () {
      final (s, e) = _range;
      return ref.read(googleCalendarServiceProvider).eventsBetween(s, e);
    }();
    final dayDate = LocalDates.parse(_day);
    final ws = LocalDates.parse(LocalDates.weekStart(_day));
    return AppPage(
      title: 'Calendar',
      eyebrow: 'GOOGLE CALENDAR · READ-ONLY · CONFIRM TO ADD',
      onRefresh: () async => _load(),
      actions: [
        IconButton(
          tooltip: 'Choose calendars',
          icon: const Icon(Icons.checklist),
          onPressed: () async {
            final changed = await showHudBottomSheet<bool>(
              context,
              title: 'Calendars to show',
              builder: (_) => const _CalendarPicker(),
            );
            if (changed == true) _load();
          },
        ),
      ],
      bottomAction: HudButton(
        expand: true,
        label: 'Plan block',
        icon: Icons.add,
        onPressed: () => _plan(),
      ),
      children: [
        SegmentedHud<_View>(
          segments: const [
            HudSegment(
              value: _View.day,
              label: 'Day',
              icon: Icons.view_day_outlined,
            ),
            HudSegment(
              value: _View.week,
              label: 'Week',
              icon: Icons.view_week_outlined,
            ),
          ],
          value: _view,
          onChanged: (v) {
            setState(() => _view = v);
            _load();
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            _NavButton(icon: Icons.chevron_left, onTap: () => _shift(-1)),
            Expanded(
              child: AnimatedSwitcher(
                duration: AppMotion.short,
                child: Text(
                  _view == _View.day
                      ? Fmt.weekdayDayMonth(dayDate)
                      : 'Week of ${Fmt.dayMonth(ws)}',
                  key: ValueKey('$_view$_day'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            _NavButton(icon: Icons.chevron_right, onTap: () => _shift(1)),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        FutureBuilder<List<CalendarEventView>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const ScanlineLoader(height: 320, lines: 0);
            }
            if (snap.hasError) {
              final e = snap.error;
              return ErrorState(
                message: e is IntegrationException
                    ? e.message
                    : 'Could not load events.',
                onRetry: _load,
              );
            }
            final events = snap.data ?? const [];
            if (_view == _View.day) {
              return _DayAgenda(
                dayKey: _day,
                events: events,
                now: now,
                wake: wake,
                sleep: sleep,
                routine: ref.watch(todaysRoutineProvider).value,
                onFree: (slot) => _plan(slot: slot),
              );
            }
            return _WeekView(
              weekStart: LocalDates.weekStart(_day),
              events: events,
              wake: wake,
              sleep: sleep,
              today: LocalDates.key(now),
              onTapDay: (key) {
                Haptics.selection();
                setState(() {
                  _day = key;
                  _view = _View.day;
                });
                _load();
              },
            );
          },
        ),
      ],
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: icon == Icons.chevron_left ? 'Previous' : 'Next',
    excludeSemantics: true,
    onTap: onTap,
    child: PressableScale(
      onTap: onTap,
      haptic: PressHaptic.none,
      pressedScale: 0.88,
      child: SizedBox.square(
        dimension: 48,
        child: Icon(icon, color: context.hud.accent),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Offline: routine timeline + honest setup
// ---------------------------------------------------------------------------

class _OfflineCalendar extends ConsumerWidget {
  const _OfflineCalendar({
    required this.configured,
    required this.row,
    required this.now,
    required this.wake,
    required this.sleep,
  });
  final bool configured;
  final IntegrationConnection? row;
  final DateTime now;
  final int wake;
  final int sleep;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final routine = ref.watch(todaysRoutineProvider).value;
    final day = LocalDates.parse(LocalDates.key(now));
    DateTime at(int m) => day.add(Duration(minutes: m));
    final blocks = [
      for (final b in routine ?? const <RoutineBlock>[])
        if (b.kind != RoutineKind.sleep)
          _Block(
            start: at(b.start),
            end: at(b.end),
            title: b.title,
            color: _routineColor(b.kind),
            kind: _BlockKind.routine,
            inset: b.atOffice,
          ),
    ];
    final error = row?.status == ConnectionStates.error;
    final c = configured ? AppColors.info : AppColors.warning;
    return AppPage(
      title: 'Calendar',
      eyebrow: configured
          ? 'GOOGLE CALENDAR · NOT CONNECTED'
          : 'GOOGLE CALENDAR · AWAITING CREDENTIALS',
      children: [
        AppCard(
          accent: c,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  HudBadge(text: 'GC', color: c, size: 40),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          !configured
                              ? 'Awaiting credentials'
                              : error
                              ? 'Reconnect Google Calendar'
                              : 'Connect Google Calendar',
                          style: t.titleSmall,
                        ),
                        Text(
                          !configured
                              ? 'This build needs a Google Cloud OAuth setup '
                                    '(GOOGLE_WEB_CLIENT_ID) before it can read '
                                    'your calendar.'
                              : row?.lastError ??
                                    'Read-only access to see your schedule '
                                        'and find free time for training.',
                          style: t.bodySmall?.copyWith(color: hud.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              HudButton.secondary(
                label: configured ? 'Go to Integrations' : 'Setup steps',
                icon: Icons.hub_outlined,
                expand: true,
                compact: true,
                onPressed: () => context.push(AppPaths.integrations),
              ),
            ],
          ),
        ),
        SectionHeader(
          'Today\'s routine',
          subtitle: routine == null ? 'Needs calibration' : 'Planned by JARVIS',
        ),
        if (blocks.isEmpty)
          GlassPanel(
            child: Text(
              'Calibrate JARVIS to see your day as a timeline here.',
              style: t.bodySmall?.copyWith(color: hud.textMuted),
            ),
          )
        else
          AppCard(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
            ),
            child: _Timeline(
              start: at(wake),
              end: at(sleep <= wake ? sleep + 1440 : sleep),
              blocks: blocks,
              now: now,
            ),
          ),
      ],
    );
  }
}

Color _routineColor(RoutineKind k) => switch (k) {
  RoutineKind.training => AppColors.strength,
  RoutineKind.meal => AppColors.protein,
  RoutineKind.office => AppColors.info,
  RoutineKind.focus => AppColors.cyan,
  RoutineKind.walk => AppColors.steps,
  RoutineKind.commute => AppColors.carbs,
  RoutineKind.ritual || RoutineKind.windDown => AppColors.sleep,
  RoutineKind.wake => AppColors.mood,
  RoutineKind.personal => AppColors.habit,
  RoutineKind.sleep => AppColors.sleep,
};

// ---------------------------------------------------------------------------
// Timeline
// ---------------------------------------------------------------------------

enum _BlockKind { event, free, routine }

class _Block {
  const _Block({
    required this.start,
    required this.end,
    required this.title,
    required this.color,
    required this.kind,
    this.onTap,
    this.inset = false,
  });
  final DateTime start;
  final DateTime end;
  final String title;
  final Color color;
  final _BlockKind kind;
  final VoidCallback? onTap;

  /// Drawn indented (e.g. focus blocks inside the office block).
  final bool inset;
}

/// Vertical HUD timeline between [start] and [end] with hour ticks, blocks
/// and a pulsing now-line.
class _Timeline extends StatelessWidget {
  const _Timeline({
    required this.start,
    required this.end,
    required this.blocks,
    required this.now,
  });

  final DateTime start;
  final DateTime end;
  final List<_Block> blocks;
  final DateTime now;

  static const _pxPerMin = 1.05;
  static const _gutter = 46.0;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final minutes = end.difference(start).inMinutes;
    final height = minutes * _pxPerMin;
    double y(DateTime t) =>
        t.difference(start).inMinutes.clamp(0, minutes) * _pxPerMin;
    final firstHour = DateTime(
      start.year,
      start.month,
      start.day,
      start.hour + (start.minute > 0 ? 1 : 0),
    );
    final hours = <DateTime>[
      for (
        var h = firstHour;
        !h.isAfter(end);
        h = h.add(const Duration(hours: 1))
      )
        h,
    ];
    final showNow = now.isAfter(start) && now.isBefore(end);
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth - _gutter;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              for (final h in hours) ...[
                Positioned(
                  left: 0,
                  top: y(h) - 6,
                  width: _gutter - 8,
                  child: Text(
                    '${h.hour.toString().padLeft(2, '0')}:00',
                    style: hud.mono(size: 9.5),
                    textAlign: TextAlign.right,
                  ),
                ),
                Positioned(
                  left: _gutter,
                  right: 0,
                  top: y(h),
                  child: Container(
                    height: 1,
                    color: hud.hairline.withValues(alpha: 0.08),
                  ),
                ),
              ],
              for (final (i, b) in blocks.indexed)
                Positioned(
                  left: _gutter + (b.inset ? w * 0.42 : 0),
                  width: w - (b.inset ? w * 0.42 : 0),
                  top: y(b.start) + 1,
                  height: math.max(18, y(b.end) - y(b.start) - 2),
                  child: Entrance(
                    delay:
                        AppMotion.staggerStep *
                        i.clamp(0, AppMotion.staggerCap),
                    offset: const Offset(12, 0),
                    child: _BlockView(block: b),
                  ),
                ),
              if (showNow)
                Positioned(
                  left: _gutter - 9,
                  right: 0,
                  top: y(now) - 9,
                  child: Row(
                    children: [
                      const HudDot(color: AppColors.red, size: 7, pulse: true),
                      Expanded(
                        child: Container(
                          height: 1.5,
                          decoration: BoxDecoration(
                            color: AppColors.red,
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.red.withValues(
                                  alpha: 0.6 * hud.glowStrength,
                                ),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _BlockView extends StatelessWidget {
  const _BlockView({required this.block});
  final _Block block;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final b = block;
    final free = b.kind == _BlockKind.free;
    final mins = b.end.difference(b.start).inMinutes;
    final tall = mins >= 40;
    final time = '${Fmt.time(b.start)} – ${Fmt.time(b.end)}';
    final title = free ? 'FREE · ${_dur(mins)}' : b.title;
    final titleStyle = free
        ? hud.label(size: tall ? 11 : 10.5, color: b.color)
        : (tall ? t.labelLarge : t.labelMedium);
    final body = Container(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.sm + 2,
        vertical: tall ? 5 : 1,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.sm),
        color: free
            ? b.color.withValues(alpha: 0.05)
            : b.color.withValues(alpha: hud.isDark ? 0.16 : 0.12),
        border: free
            ? null
            : Border(left: BorderSide(color: b.color, width: 3)),
      ),
      foregroundDecoration: free
          ? _DashedBorder(color: b.color.withValues(alpha: 0.7))
          : null,
      child: ClipRect(
        child: tall
            // Large text can make a 40-min block shorter than two lines:
            // let the time line clip instead of overflowing.
            ? OverflowBox(
                alignment: Alignment.topLeft,
                maxHeight: double.infinity,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: titleStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      free ? 'Tap to plan · $time' : time,
                      style: hud.mono(size: 9.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              )
            : Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: titleStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(Fmt.time(b.start), style: hud.mono(size: 9)),
                ],
              ),
      ),
    );
    return Semantics(
      button: b.onTap != null,
      label: free ? 'Free from $time, ${_dur(mins)}' : '${b.title}, $time',
      excludeSemantics: true,
      onTap: b.onTap,
      child: b.onTap == null
          ? body
          : PressableScale(onTap: b.onTap, pressedScale: 0.97, child: body),
    );
  }
}

String _dur(int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  if (h == 0) return '$m MIN';
  return m == 0 ? '$h H' : '$h H ${m.toString().padLeft(2, '0')}';
}

/// Dashed rounded border for free slots.
class _DashedBorder extends Decoration {
  const _DashedBorder({required this.color});
  final Color color;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _DashedPainter(color);
}

class _DashedPainter extends BoxPainter {
  _DashedPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final rect = (offset & size).deflate(0.5);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(10)));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
        d += 9;
      }
    }
  }
}

class _DayAgenda extends StatelessWidget {
  const _DayAgenda({
    required this.dayKey,
    required this.events,
    required this.now,
    required this.wake,
    required this.sleep,
    required this.onFree,
    this.routine,
  });
  final String dayKey;
  final List<CalendarEventView> events;
  final DateTime now;
  final int wake;
  final int sleep;
  final ValueChanged<TimeInterval> onFree;
  final List<RoutineBlock>? routine;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final window = wakingWindow(dayKey, wake, sleep);
    final allDay = events.where((e) => e.allDay).toList();
    final timed = events.where((e) => !e.allDay).toList();
    // Today's planned training (JARVIS routine) counts as busy time.
    final day = LocalDates.parse(dayKey);
    final training = dayKey == LocalDates.key(now)
        ? (routine ?? const <RoutineBlock>[])
              .where((b) => b.kind == RoutineKind.training)
              .map(
                (b) => TimeInterval(
                  day.add(Duration(minutes: b.start)),
                  day.add(Duration(minutes: b.end)),
                ),
              )
              .toList()
        : const <TimeInterval>[];
    final free = findFreeSlots(
      window: window,
      busy: [...busyIntervals(timed), ...training],
      minDuration: const Duration(minutes: 30),
      buffer: const Duration(minutes: 10),
    );
    final freeMin = free.fold<int>(0, (a, s) => a + s.duration.inMinutes);
    final blocks = [
      for (final s in free)
        _Block(
          start: s.start,
          end: s.end,
          title: 'Free',
          color: hud.accent,
          kind: _BlockKind.free,
          onTap: () => onFree(s),
        ),
      for (final t in training)
        _Block(
          start: t.start,
          end: t.end,
          title: 'Planned training',
          color: AppColors.strength,
          kind: _BlockKind.routine,
        ),
      for (final e in timed)
        _Block(
          start: e.start,
          end: e.end,
          title: e.title,
          color: e.isBusy ? AppColors.info : AppColors.habit,
          kind: _BlockKind.event,
          onTap: () => showHudBottomSheet<void>(
            context,
            title: e.title,
            builder: (_) => _EventSheet(event: e),
          ),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: HudReadout(
                label: 'Free time',
                value: _dur(freeMin).toLowerCase(),
                caption: '${free.length} slots ≥ 30 min while awake',
                size: 26,
                color: hud.accent,
              ),
            ),
            HudReadout(
              label: 'Events',
              value: '${events.length}',
              size: 26,
              crossAxisAlignment: CrossAxisAlignment.end,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        for (final e in allDay)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: HudChip(label: 'All day · ${e.title}', uppercase: false),
          ),
        AppCard(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
          ),
          child: blocks.isEmpty
              ? Text('Nothing scheduled', style: t.bodyMedium)
              : _Timeline(
                  start: window.start,
                  end: window.end,
                  blocks: blocks,
                  now: now,
                ),
        ),
        const SizedBox(height: 72),
      ],
    );
  }
}

class _EventSheet extends StatelessWidget {
  const _EventSheet({required this.event});
  final CalendarEventView event;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final e = event;
    final time = e.allDay
        ? 'All day'
        : '${Fmt.time(e.start)} – ${Fmt.time(e.end)}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${Fmt.weekdayDayMonth(e.start)} · $time'.toUpperCase(),
          style: hud.mono(size: 11, color: hud.accentInk),
        ),
        if (e.location != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Icon(Icons.place_outlined, size: 16, color: hud.textMuted),
              const SizedBox(width: 4),
              Expanded(child: Text(e.location!, style: t.bodyMedium)),
            ],
          ),
        ],
        if (e.description != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            e.description!,
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
            style: t.bodySmall,
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        Text(
          'CALENDAR · ${e.calendarId} · ${e.isBusy ? 'BUSY' : 'FREE'}',
          style: hud.mono(size: 10),
        ),
        if (e.htmlLink != null) ...[
          const SizedBox(height: AppSpacing.md),
          HudButton.secondary(
            label: 'Open in Google Calendar',
            icon: Icons.open_in_new,
            expand: true,
            onPressed: () => launchUrl(
              Uri.parse(e.htmlLink!),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ],
      ],
    );
  }
}

/// Seven rows of waking-day capacity bars: busy segments solid, free time
/// glowing cyan, total free time on the right.
class _WeekView extends StatelessWidget {
  const _WeekView({
    required this.weekStart,
    required this.events,
    required this.wake,
    required this.sleep,
    required this.today,
    required this.onTapDay,
  });
  final String weekStart;
  final List<CalendarEventView> events;
  final int wake;
  final int sleep;
  final String today;
  final ValueChanged<String> onTapDay;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: StaggeredList(
        gap: 0,
        children: [
          for (var i = 0; i < 7; i++)
            () {
              final key = LocalDates.addDays(weekStart, i);
              final window = wakingWindow(key, wake, sleep);
              final dayEvents = events
                  .where(
                    (ev) =>
                        !ev.allDay &&
                        ev.start.isBefore(window.end) &&
                        ev.end.isAfter(window.start),
                  )
                  .toList();
              final free = findFreeSlots(
                window: window,
                busy: busyIntervals(dayEvents),
                minDuration: const Duration(minutes: 30),
              );
              final freeMin = free.fold<int>(
                0,
                (a, s) => a + s.duration.inMinutes,
              );
              final total = window.duration.inMinutes;
              final d = LocalDates.parse(key);
              final isToday = key == today;
              return Semantics(
                button: true,
                label:
                    '${Fmt.weekdayDayMonth(d)}: ${dayEvents.length} events, '
                    '${_dur(freeMin).toLowerCase()} free',
                excludeSemantics: true,
                onTap: () => onTapDay(key),
                child: PressableScale(
                  onTap: () => onTapDay(key),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.sm + 2,
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 48,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                weekdayShort[i],
                                style: hud.label(
                                  size: 11,
                                  color: isToday ? hud.accentInk : null,
                                ),
                              ),
                              Text(
                                '${d.day}',
                                style: hud.number(
                                  size: 20,
                                  color: isToday ? hud.accentInk : hud.text,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: SizedBox(
                            height: 16,
                            child: LayoutBuilder(
                              builder: (context, box) {
                                double x(DateTime t) =>
                                    (t.difference(window.start).inMinutes /
                                            total)
                                        .clamp(0.0, 1.0) *
                                    box.maxWidth;
                                return Stack(
                                  children: [
                                    Container(
                                      decoration: BoxDecoration(
                                        color: hud.hairline.withValues(
                                          alpha: 0.06,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                    for (final s in free)
                                      Positioned(
                                        left: x(s.start),
                                        width: x(s.end) - x(s.start),
                                        top: 0,
                                        bottom: 0,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            color: hud.accent.withValues(
                                              alpha: 0.22,
                                            ),
                                            border: Border.all(
                                              color: hud.accent.withValues(
                                                alpha: 0.5,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    for (final e in dayEvents)
                                      Positioned(
                                        left: x(e.start),
                                        width: math.max(
                                          2,
                                          x(e.end) - x(e.start),
                                        ),
                                        top: 3,
                                        bottom: 3,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              2,
                                            ),
                                            color: e.isBusy
                                                ? AppColors.info
                                                : AppColors.habit,
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 70,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                _dur(freeMin).toLowerCase(),
                                style: t.labelLarge?.copyWith(
                                  color: hud.accentInk,
                                ),
                              ),
                              Text(
                                '${dayEvents.length} events',
                                style: hud.mono(size: 9.5),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Calendar picker + plan block
// ---------------------------------------------------------------------------

class _CalendarPicker extends ConsumerStatefulWidget {
  const _CalendarPicker();
  @override
  ConsumerState<_CalendarPicker> createState() => _CalendarPickerState();
}

class _CalendarPickerState extends ConsumerState<_CalendarPicker> {
  late final Future<(List<CalendarInfo>, List<String>)> _future;
  Set<String>? _selected;

  @override
  void initState() {
    super.initState();
    _future = _loadCalendars();
  }

  Future<(List<CalendarInfo>, List<String>)> _loadCalendars() async {
    final s = ref.read(googleCalendarServiceProvider);
    return (await s.listCalendars(), await s.selectedCalendarIds());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(List<CalendarInfo>, List<String>)>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) {
          final e = snap.error;
          return Text(
            e is IntegrationException ? e.message : 'Could not load.',
          );
        }
        if (!snap.hasData) return const LoadingState(compact: true);
        final (cals, sel) = snap.data!;
        _selected ??= {
          ...sel.map(
            (id) => id == 'primary'
                ? cals.where((c) => c.primary).firstOrNull?.id ?? id
                : id,
          ),
        };
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final c in cals)
              HudRow(
                title: c.name,
                subtitle: c.primary ? 'Primary' : null,
                chevron: false,
                trailing: HudToggle(
                  value: _selected!.contains(c.id),
                  semanticLabel: 'Show ${c.name}',
                  onChanged: (v) => setState(() {
                    if (v) {
                      _selected!.add(c.id);
                    } else {
                      _selected!.remove(c.id);
                    }
                  }),
                ),
              ),
            const SizedBox(height: AppSpacing.lg),
            HudButton(
              label: 'Save',
              expand: true,
              onPressed: () async {
                final sel = _selected;
                if (sel != null) {
                  await ref
                      .read(googleCalendarServiceProvider)
                      .setSelectedCalendars(sel.toList());
                }
                if (context.mounted) Navigator.pop(context, true);
              },
            ),
          ],
        );
      },
    );
  }
}

/// Create flow: kind → title/duration/day → suggested free slot → explicit
/// confirmation (with a fresh conflict check) → insert.
class _PlanBlockSheet extends ConsumerStatefulWidget {
  const _PlanBlockSheet({required this.initialDay, this.initialSlot});
  final String initialDay;

  /// A free slot tapped on the timeline (its start is preselected).
  final TimeInterval? initialSlot;

  @override
  ConsumerState<_PlanBlockSheet> createState() => _PlanBlockSheetState();
}

class _PlanBlockSheetState extends ConsumerState<_PlanBlockSheet> {
  PlanKind _kind = PlanKind.workout;
  late final TextEditingController _title = TextEditingController(
    text: PlanKind.workout.label,
  );
  late Duration _duration = PlanKind.workout.defaultDuration;
  late String _day = widget.initialDay;
  Future<List<CalendarEventView>>? _events;
  TimeInterval? _slot;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadDay();
    final s = widget.initialSlot;
    if (s != null && s.duration >= _duration) {
      _slot = TimeInterval(s.start, s.start.add(_duration));
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _loadDay() {
    final (s, e) = LocalDates.bounds(_day);
    _slot = null;
    _events = ref.read(googleCalendarServiceProvider).eventsBetween(s, e);
  }

  Future<void> _confirmAndCreate() async {
    final slot = _slot;
    if (slot == null) return;
    final service = ref.read(googleCalendarServiceProvider);
    // Fresh conflict check right before asking for confirmation.
    List<CalendarEventView> conflicts;
    try {
      conflicts = conflictsFor(
        slot,
        await service.eventsBetween(
          slot.start.subtract(const Duration(hours: 1)),
          slot.end.add(const Duration(hours: 1)),
        ),
      );
    } on IntegrationException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
    if (!mounted) return;
    if (conflicts.isNotEmpty) Haptics.warning();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add to Google Calendar?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('"${_title.text.trim()}" (${_kind.label})'),
            Text(
              '${Fmt.weekdayDayMonth(slot.start)} · '
              '${Fmt.time(slot.start)} – ${Fmt.time(slot.end)}',
            ),
            const SizedBox(height: AppSpacing.sm),
            if (conflicts.isEmpty)
              const Text('No conflicts with your selected calendars.')
            else
              Text(
                'Conflicts with: ${conflicts.map((c) => c.title).join(', ')}',
                style: const TextStyle(color: AppColors.warning),
              ),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'Google will ask once for permission to create events '
              '(calendar.events scope). Nothing else is changed.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(conflicts.isEmpty ? 'Add event' : 'Add anyway'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await service.createEvent(
        kind: _kind.key,
        title: _title.text.trim().isEmpty ? _kind.label : _title.text.trim(),
        start: slot.start,
        end: slot.end,
      );
      if (!mounted) return;
      Haptics.success();
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Event added')));
    } on CancelledException {
      if (mounted) setState(() => _saving = false);
    } on IntegrationException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final profile = ref.watch(profileProvider).value;
    final now = ref.watch(clockProvider).now();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final k in PlanKind.values)
                HudChip(
                  label: k.label,
                  selected: _kind == k,
                  onTap: () => setState(() {
                    if (_title.text == _kind.label) _title.text = k.label;
                    _kind = k;
                    _duration = k.defaultDuration;
                    _slot = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: AppSpacing.md),
          HudButton.secondary(
            label: Fmt.weekdayDayMonth(LocalDates.parse(_day)),
            icon: Icons.event,
            compact: true,
            expand: true,
            onPressed: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: LocalDates.parse(_day),
                firstDate: LocalDates.parse(LocalDates.key(now)),
                lastDate: now.add(const Duration(days: 60)),
              );
              if (d == null) return;
              setState(() {
                _day = LocalDates.key(d);
                _loadDay();
              });
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final m in [15, 30, 45, 60, 75, 90, 120])
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.xs),
                    child: HudChip(
                      label: '$m min',
                      selected: _duration.inMinutes == m,
                      onTap: () => setState(() {
                        _duration = Duration(minutes: m);
                        _slot = null;
                      }),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text('SUGGESTED FREE SLOTS', style: hud.label(size: 11)),
          const SizedBox(height: AppSpacing.sm),
          FutureBuilder<List<CalendarEventView>>(
            future: _events,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const ScanlineLoader(lines: 1);
              }
              if (snap.hasError) {
                final e = snap.error;
                return Text(
                  e is IntegrationException ? e.message : 'Could not load.',
                );
              }
              final slots = suggestSlots(
                dayKey: _day,
                events: snap.data ?? const [],
                duration: _duration,
                wakeMinutes: profile?.wakeMinutes ?? 390,
                sleepMinutes: profile?.sleepMinutes ?? 1350,
                now: now,
              );
              final options = {...slots, ?_slot}.toList()
                ..sort((a, b) => a.start.compareTo(b.start));
              if (options.isEmpty) {
                return Text(
                  'No free ${_duration.inMinutes}-minute slot between wake '
                  'and sleep time on this day.',
                  style: hud.mono(size: 11),
                );
              }
              return Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final s in options)
                    HudChip(
                      label: '${Fmt.time(s.start)}–${Fmt.time(s.end)}',
                      uppercase: false,
                      selected: _slot == s,
                      onTap: () => setState(() => _slot = s),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          HudButton(
            label: _saving ? 'Adding…' : 'Review & add',
            icon: Icons.event_available,
            expand: true,
            loading: _saving,
            onPressed: _slot == null || _saving ? null : _confirmAndCreate,
          ),
        ],
      ),
    );
  }
}
