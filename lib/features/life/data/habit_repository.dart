import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../domain/auto_rules.dart';
import '../domain/habit_models.dart';

/// Editable fields of a habit.
class HabitInput {
  const HabitInput({
    required this.name,
    this.category = HabitCategory.other,
    this.schedule = const HabitSchedule.daily(),
    this.reminderTimes = const [],
    this.notes,
    this.dependsOnHabitId,
    this.autoRule,
    this.archived = false,
  });

  factory HabitInput.fromHabit(Habit h) => HabitInput(
    name: h.name,
    category: HabitCategory.fromKey(h.category),
    schedule: scheduleOf(h),
    reminderTimes: reminderTimesOf(h),
    notes: h.notes,
    dependsOnHabitId: h.dependsOnHabitId,
    autoRule: AutoRule.fromKey(h.autoRule),
    archived: h.archived,
  );

  final String name;
  final HabitCategory category;
  final HabitSchedule schedule;
  final List<int> reminderTimes;
  final String? notes;
  final String? dependsOnHabitId;
  final AutoRule? autoRule;
  final bool archived;
}

HabitSchedule scheduleOf(Habit h) => HabitSchedule(
  type: HabitScheduleType.fromKey(h.scheduleType),
  daysMask: h.daysMask,
  targetPerWeek: h.targetPerWeek ?? 3,
);

List<int> reminderTimesOf(Habit h) {
  try {
    return parseReminderTimes(jsonDecode(h.reminderTimesJson));
  } catch (_) {
    return const [];
  }
}

/// Habit CRUD, ordering and completions.
class HabitRepository {
  HabitRepository(this._db, this._clock);
  final AppDatabase _db;
  final Clock _clock;

  DateTime get _nowUtc => _clock.now().toUtc();

  SimpleSelectStatement<$HabitsTable, Habit> _habitsQuery({
    bool includeArchived = false,
  }) {
    final q = _db.select(_db.habits)
      ..where(
        (h) => includeArchived
            ? h.deletedAt.isNull()
            : h.deletedAt.isNull() & h.archived.equals(false),
      )
      ..orderBy([
        (h) => OrderingTerm.asc(h.sortOrder),
        (h) => OrderingTerm.asc(h.createdAt),
      ]);
    return q;
  }

  Stream<List<Habit>> watchHabits({bool includeArchived = false}) =>
      _habitsQuery(includeArchived: includeArchived).watch();

  Future<List<Habit>> habits({bool includeArchived = false}) =>
      _habitsQuery(includeArchived: includeArchived).get();

  Future<Habit?> get(String id) => (_db.select(
    _db.habits,
  )..where((h) => h.id.equals(id) & h.deletedAt.isNull())).getSingleOrNull();

  Stream<Habit?> watch(String id) => (_db.select(
    _db.habits,
  )..where((h) => h.id.equals(id) & h.deletedAt.isNull())).watchSingleOrNull();

  HabitsCompanion _fields(HabitInput i) => HabitsCompanion(
    name: Value(i.name.trim()),
    category: Value(i.category.key),
    scheduleType: Value(i.schedule.type.key),
    daysMask: Value(i.schedule.daysMask & allDaysMask),
    targetPerWeek: Value(i.schedule.isWeekly ? i.schedule.weeklyTarget : null),
    reminderTimesJson: Value(jsonEncode(i.reminderTimes)),
    notes: Value(
      i.notes == null || i.notes!.trim().isEmpty ? null : i.notes!.trim(),
    ),
    dependsOnHabitId: Value(i.dependsOnHabitId),
    autoRule: Value(i.autoRule?.key),
    archived: Value(i.archived),
  );

  Future<String> create(HabitInput input) async {
    if (input.name.trim().isEmpty) {
      throw ArgumentError.value(input.name, 'name', 'must not be empty');
    }
    final id = newId();
    final maxExpr = _db.habits.sortOrder.max();
    final maxRow = await (_db.selectOnly(
      _db.habits,
    )..addColumns([maxExpr])).getSingle();
    final next = (maxRow.read(maxExpr) ?? -1) + 1;
    final now = _nowUtc;
    await _db
        .into(_db.habits)
        .insert(
          _fields(input).copyWith(
            id: Value(id),
            sortOrder: Value(next),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    return id;
  }

  Future<void> update(String id, HabitInput input) async {
    if (input.name.trim().isEmpty) {
      throw ArgumentError.value(input.name, 'name', 'must not be empty');
    }
    final dep = input.dependsOnHabitId == id ? null : input.dependsOnHabitId;
    await (_db.update(_db.habits)..where((h) => h.id.equals(id))).write(
      _fields(input)
          .copyWith(dependsOnHabitId: Value(dep), updatedAt: Value(_nowUtc)),
    );
  }

  Future<void> setArchived(String id, bool archived) =>
      (_db.update(_db.habits)..where((h) => h.id.equals(id))).write(
        HabitsCompanion(archived: Value(archived), updatedAt: Value(_nowUtc)),
      );

  /// Soft delete; dependants lose their dependency.
  Future<void> delete(String id) => _db.transaction(() async {
    final now = _nowUtc;
    await (_db.update(_db.habits)..where((h) => h.id.equals(id))).write(
      HabitsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
    await (_db.update(
      _db.habits,
    )..where((h) => h.dependsOnHabitId.equals(id))).write(
      HabitsCompanion(
        dependsOnHabitId: const Value(null),
        updatedAt: Value(now),
      ),
    );
  });

  /// Persists the given order (index = sortOrder).
  Future<void> reorder(List<String> orderedIds) => _db.transaction(() async {
    for (var i = 0; i < orderedIds.length; i++) {
      await (_db.update(_db.habits)..where((h) => h.id.equals(orderedIds[i])))
          .write(HabitsCompanion(sortOrder: Value(i)));
    }
  });

  /// Records a manual status (replacing any existing one for that day).
  Future<void> setStatus(
    String habitId,
    String localDate,
    HabitStatus status, {
    String? note,
  }) => _db.transaction(() async {
    await (_db.delete(_db.habitCompletions)..where(
          (c) => c.habitId.equals(habitId) & c.localDate.equals(localDate),
        ))
        .go();
    await _db
        .into(_db.habitCompletions)
        .insert(
          HabitCompletionsCompanion.insert(
            id: newId(),
            habitId: habitId,
            localDate: localDate,
            status: Value(status.key),
            completedAt: Value(_nowUtc),
            note: Value(note),
          ),
        );
  });

  /// Undo: removes the manual status for that day.
  Future<void> clearStatus(String habitId, String localDate) =>
      (_db.delete(_db.habitCompletions)..where(
            (c) => c.habitId.equals(habitId) & c.localDate.equals(localDate),
          ))
          .go();

  Future<List<HabitCompletion>> completions({
    String? habitId,
    String? from,
    String? to,
  }) {
    final q = _db.select(_db.habitCompletions);
    q.where((c) {
      Expression<bool> e = const Constant(true);
      if (habitId != null) e = e & c.habitId.equals(habitId);
      if (from != null) e = e & c.localDate.isBiggerOrEqualValue(from);
      if (to != null) e = e & c.localDate.isSmallerOrEqualValue(to);
      return e;
    });
    return q.get();
  }

  // ---------------------------------------------------------------------
  // AI habit suggestions (rows written by the AI coach feature).
  // ---------------------------------------------------------------------

  Stream<List<AiRecommendation>> watchPendingHabitSuggestions() =>
      (_db.select(_db.aiRecommendations)
            ..where((r) => r.kind.equals('habit') & r.status.equals('pending'))
            ..orderBy([(r) => OrderingTerm.desc(r.createdAt)]))
          .watch();

  /// accepted | edited | dismissed
  Future<void> respondToSuggestion(String id, String status) =>
      (_db.update(_db.aiRecommendations)..where((r) => r.id.equals(id))).write(
        AiRecommendationsCompanion(
          status: Value(status),
          respondedAt: Value(_nowUtc),
        ),
      );

  /// Local date of the habit's creation (in the device timezone).
  static String startDateOf(Habit h) => LocalDates.key(h.createdAt);
}

final habitRepositoryProvider = Provider<HabitRepository>(
  (ref) =>
      HabitRepository(ref.watch(databaseProvider), ref.watch(clockProvider)),
);
