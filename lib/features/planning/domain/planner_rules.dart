/// Deterministic planner proposals. Nothing here writes anywhere — the user
/// explicitly chooses which suggestions become tasks.
library;

import '../../../core/domain/free_slots.dart';

enum BlockKind { workout, mealPrep, focus }

class BlockSuggestion {
  const BlockSuggestion({
    required this.kind,
    required this.title,
    required this.slot,
    required this.reason,
  });
  final BlockKind kind;
  final String title;
  final TimeInterval slot;
  final String reason;

  /// Project tag used when the suggestion is added as a task.
  String get project => switch (kind) {
    BlockKind.workout => 'Workout',
    BlockKind.mealPrep => 'Meal prep',
    BlockKind.focus => 'Focus',
  };
}

/// Builds the planner's day window from wake/sleep minutes after midnight.
/// If sleep ≤ wake (sleep after midnight), the window ends at midnight.
TimeInterval dayWindow(DateTime day, int wakeMinutes, int sleepMinutes) {
  final midnight = DateTime(day.year, day.month, day.day);
  final start = midnight.add(Duration(minutes: wakeMinutes));
  final end = sleepMinutes > wakeMinutes
      ? midnight.add(Duration(minutes: sleepMinutes))
      : DateTime(day.year, day.month, day.day + 1);
  return TimeInterval(start, end);
}

/// Clips [window] so it starts no earlier than [now] (for today).
TimeInterval clipToNow(TimeInterval window, DateTime now) =>
    now.isAfter(window.start)
    ? TimeInterval(now.isBefore(window.end) ? now : window.end, window.end)
    : window;

/// Proposes up to one workout (60 min, earliest slot), one focus block
/// (60 min, earliest remaining slot) and one meal-prep block (45 min, latest
/// remaining slot) inside [free] slots. Blocks never overlap each other.
List<BlockSuggestion> suggestBlocks(
  List<TimeInterval> free, {
  bool includeWorkout = true,
  bool includeFocus = true,
  bool includeMealPrep = true,
}) {
  var slots = [...free]..sort((a, b) => a.start.compareTo(b.start));
  final out = <BlockSuggestion>[];

  TimeInterval? take(Duration d, {required bool latest}) {
    final fitting = slots.where((s) => s.duration >= d).toList();
    if (fitting.isEmpty) return null;
    final slot = latest ? fitting.last : fitting.first;
    final block = TimeInterval(slot.start, slot.start.add(d));
    slots = [
      for (final s in slots)
        if (s != slot)
          s
        else if (slot.end.isAfter(block.end)) ...[
          TimeInterval(block.end, slot.end),
        ],
    ]..sort((a, b) => a.start.compareTo(b.start));
    return block;
  }

  if (includeWorkout) {
    final b = take(const Duration(minutes: 60), latest: false);
    if (b != null) {
      out.add(
        BlockSuggestion(
          kind: BlockKind.workout,
          title: 'Workout',
          slot: b,
          reason: 'Earliest free 60-minute window',
        ),
      );
    }
  }
  if (includeFocus) {
    final b = take(const Duration(minutes: 60), latest: false);
    if (b != null) {
      out.add(
        BlockSuggestion(
          kind: BlockKind.focus,
          title: 'Focus block',
          slot: b,
          reason: 'Next free 60-minute window',
        ),
      );
    }
  }
  if (includeMealPrep) {
    final b = take(const Duration(minutes: 45), latest: true);
    if (b != null) {
      out.add(
        BlockSuggestion(
          kind: BlockKind.mealPrep,
          title: 'Meal prep',
          slot: b,
          reason: 'Latest free 45-minute window',
        ),
      );
    }
  }
  out.sort((a, b) => a.slot.start.compareTo(b.slot.start));
  return out;
}

/// Suggested competition-prep checklist items. The user picks which to add.
const suggestedPrepChecklist = <String>[
  'Register for the event',
  'Posing practice plan (daily sessions scheduled)',
  'Peak-week plan reviewed with a qualified coach',
  'Tan and suit logistics booked',
  'Progress-photo cadence set (e.g. weekly, same light and poses)',
  'Travel and accommodation plan',
  'Check-in documents and division rules reviewed',
  'Pack list for show day (food, water, robe, oil)',
];
