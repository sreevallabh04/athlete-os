import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/settings_repository.dart';
import '../data/journal_repository.dart';
import '../data/mood_repository.dart';
import '../domain/mood_stats.dart';

String _today(Ref ref) => LocalDates.key(ref.watch(clockProvider).now());

/// Latest mood check-in today (multiple per day are allowed).
final todayMoodProvider = StreamProvider<MoodEntry?>(
  (ref) => ref.watch(moodRepositoryProvider).watchLatestOn(_today(ref)),
);

/// Mood entries for the last [days] days including today, newest first.
final moodEntriesProvider = StreamProvider.family<List<MoodEntry>, int>((
  ref,
  days,
) {
  final today = _today(ref);
  return ref
      .watch(moodRepositoryProvider)
      .watchRange(LocalDates.addDays(today, -(days - 1)), today);
});

/// Mood entries of the calendar month starting at [monthStart] (YYYY-MM-01).
final moodMonthProvider = StreamProvider.family<List<MoodEntry>, String>((
  ref,
  monthStart,
) {
  final d = LocalDates.parse(monthStart);
  final end = LocalDates.key(DateTime(d.year, d.month + 1, 0));
  return ref.watch(moodRepositoryProvider).watchRange(monthStart, end);
});

class MoodInsights {
  const MoodInsights({
    required this.days,
    required this.trend,
    required this.entryCount,
    required this.moodVsSleepQuality,
    required this.moodVsSleepMinutes,
    required this.moodVsWorkout,
  });

  final int days;

  /// Daily mean mood, oldest first (null = no check-in that day).
  final List<(String, double?)> trend;
  final int entryCount;
  final CorrelationResult moodVsSleepQuality;

  /// Null when no sleep-duration data exists at all.
  final CorrelationResult? moodVsSleepMinutes;
  final CorrelationResult moodVsWorkout;
}

/// Trend + "observation, not causation" correlations over [days] days.
final moodInsightsProvider = FutureProvider.family<MoodInsights, int>((
  ref,
  days,
) async {
  final entries = await ref.watch(moodEntriesProvider(days).future);
  final repo = ref.watch(moodRepositoryProvider);
  final today = _today(ref);
  final start = LocalDates.addDays(today, -(days - 1));
  final points = entries.map(moodPointOf).toList();
  final moodDaily = dailyMoodMeans(points);
  final sleepQ = dailySleepQualityMeans(points);
  final sleepMin = await repo.sleepMinutesBetween(start, today);
  final workoutDays = await repo.workoutDaysBetween(start, today);
  return MoodInsights(
    days: days,
    trend: moodTrend(moodDaily, today, days),
    entryCount: entries.length,
    moodVsSleepQuality: correlate(pairByDay(sleepQ, moodDaily)),
    moodVsSleepMinutes: sleepMin.isEmpty
        ? null
        : correlate(pairByDay(sleepMin, moodDaily)),
    moodVsWorkout: correlateWithEventDays(moodDaily, workoutDays),
  );
});

final journalEntriesProvider = StreamProvider<List<JournalEntry>>(
  (ref) => ref.watch(journalRepositoryProvider).watchAll(),
);

final journalWrittenTodayProvider = StreamProvider<bool>(
  (ref) => ref.watch(journalRepositoryProvider).watchHasEntryOn(_today(ref)),
);

/// Whether the user allowed journal text to be sent to AI (default false).
final aiJournalConsentProvider = StreamProvider<bool>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watch<bool>(SettingKeys.aiJournalConsent)
      .map((v) => v ?? false),
);
