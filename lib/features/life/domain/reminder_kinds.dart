/// Reminder kinds, their persisted configuration and stable notification id
/// ranges. Pure Dart.
library;

import 'dart:convert';

import 'habit_models.dart';

/// Android notification channels (one per category so users can tune them in
/// system settings).
enum ReminderChannel {
  hydration('hydration', 'Hydration', 'Water reminders with quick logging'),
  habits('habits', 'Habits', 'Reminders for the habits you set times for'),
  planning('planning', 'Planning & reviews', 'Daily planning and reviews'),
  wellbeing('wellbeing', 'Well-being', 'Mood check-ins and journaling'),
  training('training', 'Training & nutrition', 'Workouts, steps and meals'),
  competition('competition', 'Competition prep', 'Milestones and posing'),
  summaries('summaries', 'Summaries & tests', 'Weekly summary and tests');

  const ReminderChannel(this.id, this.label, this.description);
  final String id;
  final String label;
  final String description;
}

/// How a kind is configured in the settings UI.
enum ConfigShape {
  /// Interval inside the wake window + max per day.
  interval,

  /// One time of day + weekdays.
  timeAndDays,

  /// Several times of day + weekdays.
  timesAndDays,

  /// One weekday + time (weekly).
  weekly,

  /// One time of day applied to dated items (competition milestones).
  timeOnly,

  /// Times come from elsewhere (per-habit reminder times).
  perItem,
}

enum ReminderKind {
  water(
    key: 'water',
    label: 'Water',
    description:
        'Gentle reminders through your waking hours, with a '
        '"Log 250 ml" button.',
    channel: ReminderChannel.hydration,
    shape: ConfigShape.interval,
    block: 1,
    title: 'Water check',
    body: 'Had a drink recently? Tap "Log 250 ml" to add it.',
  ),
  habit(
    key: 'habit',
    label: 'Habits',
    description: 'Uses the reminder times set on each habit.',
    channel: ReminderChannel.habits,
    shape: ConfigShape.perItem,
    block: 2,
    title: 'Habit reminder',
    body: 'Planned for now. Mark it done or skip it — both are fine.',
  ),
  planning(
    key: 'planning',
    label: 'Daily planning',
    description: 'A morning nudge to choose today\'s priorities.',
    channel: ReminderChannel.planning,
    shape: ConfigShape.timeAndDays,
    block: 3,
    title: 'Plan your day',
    body: 'Two minutes to pick today\'s priorities.',
  ),
  mood(
    key: 'mood',
    label: 'Mood check-in',
    description: 'A quick prompt to note how you feel.',
    channel: ReminderChannel.wellbeing,
    shape: ConfigShape.timeAndDays,
    block: 4,
    title: 'How are you feeling?',
    body: 'A quick mood check-in, if you\'d like.',
  ),
  journal(
    key: 'journal',
    label: 'Journaling',
    description: 'A reminder to write a few lines.',
    channel: ReminderChannel.wellbeing,
    shape: ConfigShape.timeAndDays,
    block: 5,
    title: 'Journal',
    body: 'A few lines about today, whenever you\'re ready.',
  ),
  meal(
    key: 'meal',
    label: 'Meal logging',
    description: 'Reminders around your usual meal times.',
    channel: ReminderChannel.training,
    shape: ConfigShape.timesAndDays,
    block: 6,
    title: 'Meal logging',
    body: 'Had a meal? Logging it keeps your totals accurate.',
  ),
  eodReview(
    key: 'eod_review',
    label: 'End-of-day review',
    description: 'Look back at today and set up tomorrow.',
    channel: ReminderChannel.planning,
    shape: ConfigShape.timeAndDays,
    block: 7,
    title: 'End-of-day review',
    body: 'Look back at today and set up tomorrow.',
  ),
  weeklySummary(
    key: 'weekly_summary',
    label: 'Weekly summary',
    description: 'A weekly nudge to review your week in Reports.',
    channel: ReminderChannel.summaries,
    shape: ConfigShape.weekly,
    block: 8,
    title: 'Your week in review',
    body: 'Take a look back at your week in Reports.',
  ),
  workout(
    key: 'workout',
    label: 'Workout',
    description: 'A reminder at your planned training time.',
    channel: ReminderChannel.training,
    shape: ConfigShape.timeAndDays,
    block: 9,
    title: 'Training time',
    body: 'Your planned training window is starting.',
  ),
  steps(
    key: 'steps',
    label: 'Step check',
    description:
        'A fixed-time nudge to look at your steps. The app can\'t '
        'read steps reliably in the background, so the message is generic.',
    channel: ReminderChannel.training,
    shape: ConfigShape.timeAndDays,
    block: 10,
    title: 'Step check',
    body: 'Check your step progress for today.',
  ),
  competition(
    key: 'competition',
    label: 'Competition milestones',
    description: 'Morning-of reminders for prep milestones with a due date.',
    channel: ReminderChannel.competition,
    shape: ConfigShape.timeOnly,
    block: 11,
    title: 'Prep milestone today',
    body: 'You have a competition prep milestone due today.',
  ),
  posing(
    key: 'posing',
    label: 'Posing practice',
    description: 'Reminders on the days you practise posing.',
    channel: ReminderChannel.competition,
    shape: ConfigShape.timeAndDays,
    block: 12,
    title: 'Posing practice',
    body: 'Time for your posing practice session.',
  );

  const ReminderKind({
    required this.key,
    required this.label,
    required this.description,
    required this.channel,
    required this.shape,
    required this.block,
    required this.title,
    required this.body,
  });

  final String key;
  final String label;
  final String description;
  final ReminderChannel channel;
  final ConfigShape shape;

  /// Id block number; ids for this kind are [idBase]..[idBase] + [idSpan) .
  final int block;
  final String title;
  final String body;

  static const int idSpan = 10000;

  /// Max notifications planned per kind (keeps well under Android's ~500
  /// pending alarm limit across all kinds).
  static const int maxPerKind = 120;

  /// Whether [title]/[body] are this kind's fixed, generic copy. Anything
  /// else (habit names, milestone titles) is the user's own content and is
  /// hidden on the lock screen.
  bool isGenericCopy(String title, String body) =>
      title == this.title && body == this.body;

  int get idBase => block * idSpan;
  bool ownsId(int id) => id >= idBase && id < idBase + idSpan;

  static ReminderKind? fromKey(String key) {
    for (final k in values) {
      if (k.key == key) return k;
    }
    return null;
  }

  static ReminderKind? forId(int id) {
    for (final k in values) {
      if (k.ownsId(id)) return k;
    }
    return null;
  }

  ReminderConfig get defaults => switch (this) {
    water => const ReminderConfig(intervalMinutes: 120, maxPerDay: 8),
    habit => const ReminderConfig(),
    planning => const ReminderConfig(times: [480]),
    mood => const ReminderConfig(times: [1230]),
    journal => const ReminderConfig(times: [1290]),
    meal => const ReminderConfig(times: [510, 780, 1170]),
    eodReview => const ReminderConfig(times: [1260]),
    weeklySummary => ReminderConfig(
      times: const [1140],
      daysMask: weekdayBit(7),
    ),
    workout => const ReminderConfig(times: [1050], daysMask: 0x15),
    steps => const ReminderConfig(times: [1080]),
    competition => const ReminderConfig(times: [480]),
    posing => const ReminderConfig(times: [1140], daysMask: 0x2A),
  };
}

/// Notification ids used outside the per-kind blocks.
abstract final class SpecialNotificationIds {
  static const test = 1;
  static const waterSnooze = 2;
}

/// Kind-specific configuration persisted in `notification_prefs.configJson`.
class ReminderConfig {
  const ReminderConfig({
    this.times = const [],
    this.daysMask = allDaysMask,
    this.intervalMinutes = 120,
    this.maxPerDay = 8,
  });

  /// Minutes after local midnight.
  final List<int> times;

  /// Bit0 = Monday … bit6 = Sunday.
  final int daysMask;
  final int intervalMinutes;
  final int maxPerDay;

  ReminderConfig copyWith({
    List<int>? times,
    int? daysMask,
    int? intervalMinutes,
    int? maxPerDay,
  }) => ReminderConfig(
    times: times ?? this.times,
    daysMask: daysMask ?? this.daysMask,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    maxPerDay: maxPerDay ?? this.maxPerDay,
  );

  Map<String, Object> toJson() => {
    'times': times,
    'daysMask': daysMask,
    'intervalMinutes': intervalMinutes,
    'maxPerDay': maxPerDay,
  };

  String encode() => jsonEncode(toJson());

  /// Lenient parse: unknown/missing fields fall back to [defaults].
  static ReminderConfig parse(String? json, ReminderConfig defaults) {
    if (json == null || json.trim().isEmpty) return defaults;
    try {
      final m = jsonDecode(json);
      if (m is! Map) return defaults;
      final times = m.containsKey('times')
          ? parseReminderTimes(m['times'])
          : defaults.times;
      final mask = m['daysMask'];
      final interval = m['intervalMinutes'];
      final max = m['maxPerDay'];
      return ReminderConfig(
        times: times,
        daysMask: mask is num ? mask.toInt() & allDaysMask : defaults.daysMask,
        intervalMinutes: interval is num
            ? interval.toInt().clamp(15, 720)
            : defaults.intervalMinutes,
        maxPerDay: max is num ? max.toInt().clamp(1, 24) : defaults.maxPerDay,
      );
    } catch (_) {
      return defaults;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ReminderConfig &&
      other.daysMask == daysMask &&
      other.intervalMinutes == intervalMinutes &&
      other.maxPerDay == maxPerDay &&
      other.times.length == times.length &&
      Iterable.generate(times.length).every((i) => other.times[i] == times[i]);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(times), daysMask, intervalMinutes, maxPerDay);
}

/// A kind's persisted preference.
class ReminderPref {
  const ReminderPref({
    required this.kind,
    required this.enabled,
    required this.config,
  });
  final ReminderKind kind;
  final bool enabled;
  final ReminderConfig config;
}
