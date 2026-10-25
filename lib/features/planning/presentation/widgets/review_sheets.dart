import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/util/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../data/metrics_queries.dart';
import '../../data/planning_repository.dart';
import '../../domain/habit_schedule.dart';
import '../../domain/report_builder.dart';
import 'ui_helpers.dart';

/// End-of-day review. The note is stored under AppSettings `review.<date>`;
/// nothing is written to the journal.
class EndOfDayReviewSheet extends ConsumerStatefulWidget {
  const EndOfDayReviewSheet({super.key, required this.date});
  final String date;

  @override
  ConsumerState<EndOfDayReviewSheet> createState() =>
      _EndOfDayReviewSheetState();
}

class _DayFacts {
  const _DayFacts({
    required this.doneTitles,
    required this.totalTasks,
    required this.habits,
    required this.mood,
    required this.existingNote,
  });
  final List<String> doneTitles;
  final int totalTasks;
  final HabitTally habits;
  final int? mood;
  final String? existingNote;
}

class _EndOfDayReviewSheetState extends ConsumerState<EndOfDayReviewSheet> {
  final _note = TextEditingController();
  late final Future<_DayFacts> _facts = _load();

  Future<_DayFacts> _load() async {
    final repo = ref.read(planningRepositoryProvider);
    final q = ref.read(metricsQueriesProvider);
    final tasks = await repo.tasksOn(widget.date);
    final habits = await q.habits();
    final marks = await q.habitMarks(
      LocalDates.weekStart(widget.date),
      widget.date,
    );
    final moods = await q.moods(widget.date, widget.date);
    final review = await repo.dayReview(widget.date);
    final note = review?['note'] as String?;
    if (note != null) _note.text = note;
    return _DayFacts(
      doneTitles: [
        for (final t in tasks)
          if (t.done) t.title,
      ],
      totalTasks: tasks.length,
      habits: tallyHabits(habits, widget.date, marks),
      mood: moods.isEmpty ? null : moods.last.mood,
      existingNote: note,
    );
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        MediaQuery.viewInsetsOf(context).bottom + AppSpacing.xl,
      ),
      child: FutureBuilder<_DayFacts>(
        future: _facts,
        builder: (context, snap) {
          if (!snap.hasData) return const LoadingState();
          final f = snap.data!;
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('End-of-day review', style: t.titleLarge),
                Text(
                  formatDateKey(widget.date).toUpperCase(),
                  style: context.hud.mono(
                    size: 10.5,
                    color: context.hud.accentInk,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  children: [
                    Expanded(
                      child: StatTile(
                        label: 'Priorities',
                        value: '${f.doneTitles.length}/${f.totalTasks}',
                      ),
                    ),
                    Expanded(
                      child: StatTile(
                        label: 'Habits',
                        value: f.habits.total == 0
                            ? '—'
                            : '${f.habits.done}/${f.habits.total}',
                        color: AppColors.habit,
                      ),
                    ),
                    Expanded(
                      child: StatTile(
                        label: 'Mood',
                        value: f.mood == null ? '—' : '${f.mood}/5',
                        color: AppColors.mood,
                      ),
                    ),
                  ],
                ),
                if (f.doneTitles.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  for (final d in f.doneTitles)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.check,
                            size: 16,
                            color: AppColors.success,
                          ),
                          const SizedBox(width: 6),
                          Expanded(child: Text(d)),
                        ],
                      ),
                    ),
                ],
                const SizedBox(height: AppSpacing.lg),
                TextField(
                  controller: _note,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'One note about today',
                    helperText:
                        'Saved with your planner (not added to your journal).',
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                HudButton(
                  label: 'Save review',
                  icon: Icons.check,
                  expand: true,
                  onPressed: () async {
                    await ref.read(planningRepositoryProvider).saveDayReview(
                      widget.date,
                      {
                        'note': _note.text.trim(),
                        'tasksDone': f.doneTitles.length,
                        'tasksTotal': f.totalTasks,
                        'habitsDone': f.habits.done,
                        'habitsDue': f.habits.total,
                        'mood': f.mood,
                        'savedAt': ref
                            .read(clockProvider)
                            .now()
                            .toUtc()
                            .toIso8601String(),
                      },
                    );
                    Haptics.success();
                    if (context.mounted) {
                      Navigator.pop(context);
                      showSnack(context, 'Review saved. Rest well.');
                    }
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Weekly review: deterministic aggregates + the user's reflection, saved to
/// the `reports` table with kind `weekly_review`.
class WeeklyReviewSheet extends ConsumerStatefulWidget {
  const WeeklyReviewSheet({super.key, required this.anyDateInWeek});
  final String anyDateInWeek;

  @override
  ConsumerState<WeeklyReviewSheet> createState() => _WeeklyReviewSheetState();
}

class _WeeklyReviewSheetState extends ConsumerState<WeeklyReviewSheet> {
  final _wins = TextEditingController();
  final _challenges = TextEditingController();
  final _focus = TextEditingController();
  late final String _start = LocalDates.weekStart(widget.anyDateInWeek);
  late final String _end = LocalDates.addDays(_start, 6);
  late final Future<(Map<String, num?>, int, int)> _data = _load();

  Future<(Map<String, num?>, int, int)> _load() async {
    final q = ref.read(metricsQueriesProvider);
    final repo = ref.read(planningRepositoryProvider);
    final input = await q.reportInput(
      kind: 'weekly',
      start: _start,
      end: _end,
      now: ref.read(clockProvider).now(),
    );
    final numbers = ReportBuilder.computeNumbers(input);
    final tasks = await repo.tasksBetween(_start, _end);
    final existing = await repo.weeklyReview(_start);
    if (existing != null) {
      try {
        final j = jsonDecode(existing.contentJson) as Map<String, dynamic>;
        final r = (j['reflection'] as Map?)?.cast<String, dynamic>() ?? {};
        _wins.text = r['wins'] as String? ?? '';
        _challenges.text = r['challenges'] as String? ?? '';
        _focus.text = r['nextFocus'] as String? ?? '';
      } catch (_) {}
    }
    return (numbers, tasks.where((t) => t.done).length, tasks.length);
  }

  @override
  void dispose() {
    _wins.dispose();
    _challenges.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        MediaQuery.viewInsetsOf(context).bottom + AppSpacing.xl,
      ),
      child: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return const ErrorState(message: 'Could not load this week.');
          }
          if (!snap.hasData) return const LoadingState();
          final (n, done, total) = snap.data!;
          String v(String key, String Function(num) f) =>
              n[key] == null ? 'No data' : f(n[key]!);
          final rows = <(String, String)>[
            ('Priorities done', '$done of $total'),
            ('Workouts', '${n['strength.workouts']}'),
            (
              'Running',
              n['run.count'] == 0
                  ? 'No runs'
                  : '${(n['run.distanceKm']!).toStringAsFixed(1)} km · '
                        '${n['run.count']} runs',
            ),
            (
              'Food logged',
              '${n['nutrition.loggedDays']} of ${n['days']} days',
            ),
            (
              'Protein target hit',
              v(
                'nutrition.proteinAdherencePct',
                (x) => '${x.round()}% of logged days',
              ),
            ),
            ('Avg steps', v('steps.avg', (x) => Fmt.integer(x))),
            (
              'Habit completion',
              v('habits.completionPct', (x) => '${x.round()}%'),
            ),
            ('Avg mood', v('mood.avg', (x) => '${x.toStringAsFixed(1)} / 5')),
          ];
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Weekly review', style: t.titleLarge),
                Hint(
                  '${formatDateKey(_start, pattern: 'd MMM')} – '
                  '${formatDateKey(_end, pattern: 'd MMM yyyy')}',
                ),
                const SizedBox(height: AppSpacing.md),
                for (final (label, value) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(child: Text(label, style: t.bodyMedium)),
                        Text(value, style: t.labelLarge),
                      ],
                    ),
                  ),
                const SizedBox(height: AppSpacing.lg),
                TextField(
                  controller: _wins,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'What went well?',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _challenges,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'What was hard?',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _focus,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'One focus for next week',
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: () async {
                    await ref
                        .read(planningRepositoryProvider)
                        .saveReport(
                          kind: 'weekly_review',
                          replaceSamePeriod: true,
                          periodStart: _start,
                          periodEnd: _end,
                          content: {
                            'version': 1,
                            'aggregates': n,
                            'tasksDone': done,
                            'tasksTotal': total,
                            'reflection': {
                              'wins': _wins.text.trim(),
                              'challenges': _challenges.text.trim(),
                              'nextFocus': _focus.text.trim(),
                            },
                          },
                        );
                    if (context.mounted) {
                      Navigator.pop(context);
                      showSnack(context, 'Weekly review saved');
                    }
                  },
                  child: const Text('Save weekly review'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
