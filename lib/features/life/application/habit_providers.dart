import 'package:drift/drift.dart' show Table, TableInfo;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../data/auto_rule_repository.dart';
import '../data/habit_repository.dart';
import '../data/watch_tables.dart';
import '../domain/auto_rules.dart';
import '../domain/habit_engine.dart';
import '../domain/habit_models.dart';

/// Everything the UI needs to know about one habit.
class HabitView {
  const HabitView({
    required this.habit,
    required this.schedule,
    required this.startDate,
    required this.marks,
    required this.todayMark,
    required this.dueToday,
    required this.streak,
    required this.week,
    required this.weekDone,
    required this.autoRule,
    required this.reminderTimes,
    required this.upNext,
    required this.dependsOnName,
  });

  final Habit habit;
  final HabitSchedule schedule;
  final String startDate;

  /// Effective marks (manual + automatic) by local date.
  final Map<String, DayMark> marks;
  final DayMark? todayMark;
  final bool dueToday;
  final StreakResult streak;
  final CompletionStats week;

  /// Done count in the current ISO week (for weekly-target habits).
  final int weekDone;
  final AutoRule? autoRule;
  final List<int> reminderTimes;

  /// The prerequisite habit is done today and this one is still open.
  final bool upNext;
  final String? dependsOnName;

  String get id => habit.id;
  String get name => habit.name;
}

class HabitBoard {
  const HabitBoard({required this.today, required this.habits});
  final String today;

  /// Active (non-archived) habits in the user's order.
  final List<HabitView> habits;

  List<HabitView> get dueToday => habits.where((h) => h.dueToday).toList();
  List<HabitView> get notDueToday => habits.where((h) => !h.dueToday).toList();

  int get doneToday =>
      dueToday.where((h) => h.todayMark?.isDone ?? false).length;
  int get skippedToday =>
      dueToday.where((h) => h.todayMark?.isSkipped ?? false).length;

  /// Due today and not yet marked done or skipped.
  int get remainingToday => dueToday.where((h) => h.todayMark == null).length;

  CompletionStats get weekTotal =>
      habits.fold(CompletionStats.zero, (a, h) => a + h.week);
}

/// Builds the habit board from the database. Exposed for tests.
class HabitBoardLoader {
  HabitBoardLoader(this._db, this._habits, this._auto);
  final AppDatabase _db;
  final HabitRepository _habits;
  final AutoRuleRepository _auto;

  /// Longest history used for streaks and auto rules.
  static const historyDays = 400;

  List<TableInfo<Table, Object?>> get watchedTables => [
    _db.habits,
    _db.habitCompletions,
    ..._auto.watchedTables,
  ];

  Future<HabitBoard> load(String today, {bool includeArchived = false}) async {
    final habits = await _habits.habits(includeArchived: includeArchived);
    if (habits.isEmpty) return HabitBoard(today: today, habits: const []);
    final from = LocalDates.addDays(today, -historyDays);
    final completions = await _habits.completions(from: from, to: today);
    final manualByHabit = <String, Map<String, HabitStatus>>{};
    for (final c in completions) {
      final s = HabitStatus.fromKey(c.status);
      if (s == null) continue;
      (manualByHabit[c.habitId] ??= {})[c.localDate] = s;
    }

    // Auto rules: evaluate once for the earliest relevant start date.
    final autoHabits = habits.where(
      (h) => AutoRule.fromKey(h.autoRule) != null,
    );
    Map<String, AutoRuleDay> autoDays = const {};
    if (autoHabits.isNotEmpty) {
      var start = today;
      for (final h in autoHabits) {
        final s = HabitRepository.startDateOf(h);
        if (s.compareTo(start) < 0) start = s;
      }
      if (start.compareTo(from) < 0) start = from;
      autoDays = await _auto.daysBetween(start, today);
    }

    final names = {for (final h in habits) h.id: h.name};
    final views = <HabitView>[];
    for (final h in habits) {
      final schedule = scheduleOf(h);
      final rule = AutoRule.fromKey(h.autoRule);
      final startDate = HabitRepository.startDateOf(h);
      final autoDone = <String>{};
      if (rule != null) {
        autoDays.forEach((d, day) {
          if (d.compareTo(startDate) >= 0 && autoRuleMet(rule, day)) {
            autoDone.add(d);
          }
        });
      }
      final marks = mergeMarks(manualByHabit[h.id] ?? const {}, autoDone);
      views.add(
        HabitView(
          habit: h,
          schedule: schedule,
          startDate: startDate,
          marks: marks,
          todayMark: marks[today],
          dueToday: HabitEngine.isDueOn(
            schedule,
            today,
            marks: marks,
            startDate: startDate.compareTo(today) > 0 ? today : startDate,
          ),
          streak: HabitEngine.streaks(
            schedule: schedule,
            marks: marks,
            today: today,
            startDate: startDate,
          ),
          week: HabitEngine.weekProgress(
            schedule: schedule,
            marks: marks,
            today: today,
            startDate: startDate,
          ),
          weekDone: HabitEngine.doneInWeek(marks, today),
          autoRule: rule,
          reminderTimes: reminderTimesOf(h),
          upNext: false,
          dependsOnName: h.dependsOnHabitId == null
              ? null
              : names[h.dependsOnHabitId],
        ),
      );
    }

    final next = HabitEngine.suggestedNext([
      for (final v in views)
        HabitDependencyView(
          id: v.id,
          dependsOnId: v.habit.dependsOnHabitId,
          dueToday: v.dueToday,
          todayMark: v.todayMark,
        ),
    ]);
    return HabitBoard(
      today: today,
      habits: [for (final v in views) next.contains(v.id) ? _withUpNext(v) : v],
    );
  }

  HabitView _withUpNext(HabitView v) => HabitView(
    habit: v.habit,
    schedule: v.schedule,
    startDate: v.startDate,
    marks: v.marks,
    todayMark: v.todayMark,
    dueToday: v.dueToday,
    streak: v.streak,
    week: v.week,
    weekDone: v.weekDone,
    autoRule: v.autoRule,
    reminderTimes: v.reminderTimes,
    upNext: true,
    dependsOnName: v.dependsOnName,
  );
}

final habitBoardLoaderProvider = Provider<HabitBoardLoader>(
  (ref) => HabitBoardLoader(
    ref.watch(databaseProvider),
    ref.watch(habitRepositoryProvider),
    ref.watch(autoRuleRepositoryProvider),
  ),
);

/// Live habit board for today.
final habitBoardProvider = StreamProvider<HabitBoard>((ref) {
  final db = ref.watch(databaseProvider);
  final loader = ref.watch(habitBoardLoaderProvider);
  final clock = ref.watch(clockProvider);
  return watchTables(
    db,
    loader.watchedTables,
    () => loader.load(LocalDates.key(clock.now())),
  );
});

/// One habit (archived included) with its marks and stats; null if deleted.
final habitDetailProvider = StreamProvider.family<HabitView?, String>((
  ref,
  id,
) {
  final db = ref.watch(databaseProvider);
  final loader = ref.watch(habitBoardLoaderProvider);
  final clock = ref.watch(clockProvider);
  return watchTables(db, loader.watchedTables, () async {
    final board = await loader.load(
      LocalDates.key(clock.now()),
      includeArchived: true,
    );
    for (final h in board.habits) {
      if (h.id == id) return h;
    }
    return null;
  });
});

/// All habits including archived (for management and dependency pickers).
final allHabitsProvider = StreamProvider<List<Habit>>(
  (ref) =>
      ref.watch(habitRepositoryProvider).watchHabits(includeArchived: true),
);

final pendingHabitSuggestionsProvider = StreamProvider<List<AiRecommendation>>(
  (ref) => ref.watch(habitRepositoryProvider).watchPendingHabitSuggestions(),
);
