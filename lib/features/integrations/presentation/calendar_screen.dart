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
import '../../../data/repositories/integration_status_repository.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../train/application/train_providers.dart';
import '../data/api_errors.dart';
import '../data/google_calendar_service.dart';
import '../domain/slot_suggestions.dart';

enum _View { day, week }

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
    setState(() {
      _day = LocalDates.addDays(_day, dir * (_view == _View.day ? 1 : 7));
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final row = ref
        .watch(integrationStatusProvider(Providers.googleCalendar))
        .value;
    if (!Env.hasGoogle) {
      return AppPage(
        title: 'Calendar',
        children: [
          NoticeBanner(
            message:
                'Awaiting credentials: Google Calendar needs a Google Cloud '
                'OAuth setup (GOOGLE_WEB_CLIENT_ID). See '
                'docs/integrations/google-calendar.md.',
            color: AppColors.warning,
            actionLabel: 'Setup',
            onAction: () => context.push(AppPaths.integrations),
          ),
        ],
      );
    }
    if (!isConnected(row)) {
      return AppPage(
        title: 'Calendar',
        children: [
          EmptyState(
            icon: Icons.calendar_month,
            title: row?.status == ConnectionStates.error
                ? 'Reconnect Google Calendar'
                : 'Connect Google Calendar',
            message:
                row?.lastError ??
                'Read-only access to see your schedule and find free time '
                    'for training.',
            actionLabel: 'Go to Integrations',
            onAction: () => context.push(AppPaths.integrations),
          ),
        ],
      );
    }
    _future ??= () {
      final (s, e) = _range;
      return ref.read(googleCalendarServiceProvider).eventsBetween(s, e);
    }();
    final dayDate = LocalDates.parse(_day);
    return AppPage(
      title: 'Calendar',
      onRefresh: () async => _load(),
      actions: [
        IconButton(
          tooltip: 'Choose calendars',
          icon: const Icon(Icons.checklist),
          onPressed: () async {
            final changed = await showDialog<bool>(
              context: context,
              builder: (_) => const _CalendarPicker(),
            );
            if (changed == true) _load();
          },
        ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final created = await showModalBottomSheet<bool>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (_) => _PlanBlockSheet(initialDay: _day),
          );
          if (created == true) _load();
        },
        icon: const Icon(Icons.add),
        label: const Text('Plan block'),
      ),
      children: [
        SegmentedButton<_View>(
          segments: const [
            ButtonSegment(value: _View.day, label: Text('Day')),
            ButtonSegment(value: _View.week, label: Text('Week')),
          ],
          selected: {_view},
          onSelectionChanged: (s) {
            setState(() => _view = s.first);
            _load();
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            IconButton(
              tooltip: 'Previous',
              onPressed: () => _shift(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                _view == _View.day
                    ? Fmt.weekdayDayMonth(dayDate)
                    : 'Week of ${Fmt.dayMonth(LocalDates.parse(LocalDates.weekStart(_day)))}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Next',
              onPressed: () => _shift(1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        FutureBuilder<List<CalendarEventView>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const LoadingState();
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
              return _DayAgenda(events: events);
            }
            final ws = LocalDates.weekStart(_day);
            return Column(
              children: [
                for (var i = 0; i < 7; i++)
                  () {
                    final key = LocalDates.addDays(ws, i);
                    final (s, e) = LocalDates.bounds(key);
                    final dayEvents = events
                        .where(
                          (ev) => ev.start.isBefore(e) && ev.end.isAfter(s),
                        )
                        .toList();
                    return _WeekDayRow(
                      dayKey: key,
                      events: dayEvents,
                      onTapDay: () {
                        setState(() {
                          _day = key;
                          _view = _View.day;
                        });
                        _load();
                      },
                    );
                  }(),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _DayAgenda extends StatelessWidget {
  const _DayAgenda({required this.events});
  final List<CalendarEventView> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const EmptyState(
        icon: Icons.event_available,
        title: 'Nothing scheduled',
        message: 'A good day to plan a workout or a focus block.',
        compact: true,
      );
    }
    return Column(children: [for (final e in events) _EventTile(event: e)]);
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});
  final CalendarEventView event;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final e = event;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.md),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          builder: (_) => _EventSheet(event: e),
        ),
        semanticLabel: '${e.title}, ${_timeLabel(e)}',
        child: Row(
          children: [
            Container(
              width: 4,
              height: 36,
              decoration: BoxDecoration(
                color: e.isBusy
                    ? AppColors.info
                    : AppColors.info.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.title, style: t.titleSmall),
                  Text(
                    _timeLabel(e) + (e.isBusy ? '' : ' · free'),
                    style: t.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _timeLabel(CalendarEventView e) =>
    e.allDay ? 'All day' : '${Fmt.time(e.start)} – ${Fmt.time(e.end)}';

class _EventSheet extends StatelessWidget {
  const _EventSheet({required this.event});
  final CalendarEventView event;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final e = event;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(e.title, style: t.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          Text('${Fmt.weekdayDayMonth(e.start)} · ${_timeLabel(e)}'),
          if (e.location != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                const Icon(Icons.place_outlined, size: 16),
                const SizedBox(width: 4),
                Expanded(child: Text(e.location!)),
              ],
            ),
          ],
          if (e.description != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(e.description!, maxLines: 8, overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Calendar: ${e.calendarId} · ${e.isBusy ? 'busy' : 'free'}',
            style: t.bodySmall,
          ),
          if (e.htmlLink != null)
            TextButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(e.htmlLink!),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open in Google Calendar'),
            ),
        ],
      ),
    );
  }
}

class _WeekDayRow extends StatelessWidget {
  const _WeekDayRow({
    required this.dayKey,
    required this.events,
    required this.onTapDay,
  });
  final String dayKey;
  final List<CalendarEventView> events;
  final VoidCallback onTapDay;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final d = LocalDates.parse(dayKey);
    return InkWell(
      onTap: onTapDay,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
              child: Text(Fmt.weekdayDayMonth(d), style: t.labelLarge),
            ),
            Expanded(
              child: events.isEmpty
                  ? Text('Free', style: t.bodySmall)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final e in events.take(5))
                          Text(
                            '${_timeLabel(e)}  ${e.title}',
                            style: t.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (events.length > 5)
                          Text(
                            '+${events.length - 5} more',
                            style: t.bodySmall,
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

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
    return AlertDialog(
      title: const Text('Calendars to show'),
      content: SizedBox(
        width: 400,
        child: FutureBuilder<(List<CalendarInfo>, List<String>)>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) {
              final e = snap.error;
              return Text(
                e is IntegrationException ? e.message : 'Could not load.',
              );
            }
            if (!snap.hasData) return const LoadingState();
            final (cals, sel) = snap.data!;
            _selected ??= {
              ...sel.map(
                (id) => id == 'primary'
                    ? cals.where((c) => c.primary).firstOrNull?.id ?? id
                    : id,
              ),
            };
            return ListView(
              shrinkWrap: true,
              children: [
                for (final c in cals)
                  CheckboxListTile(
                    value: _selected!.contains(c.id),
                    title: Text(c.name),
                    subtitle: c.primary ? const Text('Primary') : null,
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _selected!.add(c.id);
                      } else {
                        _selected!.remove(c.id);
                      }
                    }),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            final sel = _selected;
            if (sel != null) {
              await ref
                  .read(googleCalendarServiceProvider)
                  .setSelectedCalendars(sel.toList());
            }
            if (context.mounted) Navigator.pop(context, true);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Create flow: kind → title/duration/day → suggested free slot → explicit
/// confirmation (with a fresh conflict check) → insert.
class _PlanBlockSheet extends ConsumerStatefulWidget {
  const _PlanBlockSheet({required this.initialDay});
  final String initialDay;

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
    final t = Theme.of(context).textTheme;
    final profile = ref.watch(profileProvider).value;
    final now = ref.watch(clockProvider).now();
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.gutter,
        right: AppSpacing.gutter,
        top: AppSpacing.lg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Plan a block', style: t.titleLarge),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                for (final k in PlanKind.values)
                  ChoiceChip(
                    label: Text(k.label),
                    selected: _kind == k,
                    onSelected: (_) => setState(() {
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
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.event),
                    label: Text(Fmt.weekdayDayMonth(LocalDates.parse(_day))),
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
                ),
                const SizedBox(width: AppSpacing.md),
                DropdownButton<int>(
                  value: _duration.inMinutes,
                  items: [
                    for (final m in [15, 30, 45, 60, 75, 90, 120])
                      DropdownMenuItem(value: m, child: Text('$m min')),
                  ],
                  onChanged: (v) => setState(() {
                    _duration = Duration(minutes: v ?? 60);
                    _slot = null;
                  }),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Suggested free slots', style: t.labelLarge),
            const SizedBox(height: AppSpacing.sm),
            FutureBuilder<List<CalendarEventView>>(
              future: _events,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const LinearProgressIndicator();
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
                if (slots.isEmpty) {
                  return Text(
                    'No free ${_duration.inMinutes}-minute slot between wake '
                    'and sleep time on this day.',
                    style: t.bodySmall,
                  );
                }
                return Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final s in slots)
                      ChoiceChip(
                        label: Text('${Fmt.time(s.start)}–${Fmt.time(s.end)}'),
                        selected: _slot == s,
                        onSelected: (_) => setState(() => _slot = s),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _slot == null || _saving ? null : _confirmAndCreate,
                child: Text(_saving ? 'Adding…' : 'Review & add'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
