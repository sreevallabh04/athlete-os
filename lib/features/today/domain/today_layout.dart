/// Deterministic, time-aware ordering of the Today command deck. Pure Dart.
///
/// The deck front-loads what matters *now*:
/// * morning: the briefing and today's session (he trains early),
/// * daytime: targets and quick logging,
/// * evening: the review rituals (mood, journal, end-of-day review).
library;

enum DayPhase { morning, day, evening }

enum TodaySection {
  /// One-line JARVIS briefing strip.
  briefing,

  /// Concentric daily-targets reactor.
  targets,

  /// Glass quick actions (water, meal, mood, train).
  quickActions,

  /// Today's planned training session.
  session,

  /// Next routine blocks with a "now" line.
  routine,

  /// Top-3 priorities.
  priorities,

  /// Calendar: next events.
  agenda,

  /// Habit chips.
  habits,

  /// Mood, journal and the end-of-day review.
  review,

  /// Sleep, heart rate, runs, last workout.
  vitals,

  /// Competition countdown (gold).
  competition,

  /// Messaging assistant drafts awaiting approval.
  inbox,
}

/// 04:00–11:59 morning, 12:00–17:59 day, otherwise evening.
DayPhase dayPhaseOf(DateTime now) {
  final h = now.hour;
  if (h >= 4 && h < 12) return DayPhase.morning;
  if (h >= 12 && h < 18) return DayPhase.day;
  return DayPhase.evening;
}

/// Section order for [now]. A session that is already logged ([sessionDone])
/// drops below the fold; nothing else is ever hidden by these rules.
List<TodaySection> todaySectionOrder(DateTime now, {bool sessionDone = false}) {
  final order = switch (dayPhaseOf(now)) {
    DayPhase.morning => [
      TodaySection.briefing,
      TodaySection.session,
      TodaySection.targets,
      TodaySection.quickActions,
      TodaySection.routine,
      TodaySection.priorities,
      TodaySection.agenda,
      TodaySection.habits,
      TodaySection.competition,
      TodaySection.inbox,
      TodaySection.vitals,
      TodaySection.review,
    ],
    DayPhase.day => [
      TodaySection.briefing,
      TodaySection.targets,
      TodaySection.quickActions,
      TodaySection.routine,
      TodaySection.priorities,
      TodaySection.agenda,
      TodaySection.session,
      TodaySection.habits,
      TodaySection.inbox,
      TodaySection.competition,
      TodaySection.vitals,
      TodaySection.review,
    ],
    DayPhase.evening => [
      TodaySection.briefing,
      TodaySection.review,
      TodaySection.targets,
      TodaySection.quickActions,
      TodaySection.habits,
      TodaySection.priorities,
      TodaySection.routine,
      TodaySection.vitals,
      TodaySection.session,
      TodaySection.agenda,
      TodaySection.competition,
      TodaySection.inbox,
    ],
  };
  if (sessionDone) {
    order
      ..remove(TodaySection.session)
      ..insert(order.indexOf(TodaySection.vitals) + 1, TodaySection.session);
  }
  return order;
}

/// "Good morning" / "Good afternoon" / "Good evening" (and "Good night"
/// before 05:00), with the name when known. Same rule as the boot sequence.
String greetingFor(DateTime now, String? name) {
  final h = now.hour;
  final part = h < 5
      ? 'Good night'
      : h < 12
      ? 'Good morning'
      : h < 17
      ? 'Good afternoon'
      : 'Good evening';
  final n = name?.trim();
  return n == null || n.isEmpty ? '$part.' : '$part, $n.';
}
