/// Deterministic daily timeline from wake/office/training/sleep times.
/// Pure Dart.
library;

import 'dart:math' as math;

import 'calibration.dart';

enum RoutineKind {
  wake('Wake'),
  training('Training'),
  meal('Meal'),
  commute('Commute'),
  office('Office'),
  focus('Focus block'),
  walk('Walk'),
  ritual('Check-in'),
  personal('Personal'),
  windDown('Wind-down'),
  sleep('Sleep');

  const RoutineKind(this.label);
  final String label;
}

class RoutineBlock {
  const RoutineBlock({
    required this.start,
    required this.end,
    required this.kind,
    required this.title,
    this.detail,
    this.atOffice = false,
    this.proteinG,
  });

  /// Minutes after midnight; [end] > [start] (sleep ends at 24:00).
  final int start;
  final int end;
  final RoutineKind kind;
  final String title;
  final String? detail;

  /// True for blocks that happen inside the office window (focus blocks,
  /// lunch at the desk). All other blocks never overlap the office block.
  final bool atOffice;
  final int? proteinG;

  int get minutes => end - start;
  String get timeLabel => '${hhmm(start)}–${hhmm(end)}';
  bool overlaps(RoutineBlock o) => start < o.end && o.start < end;
}

class RoutineInput {
  const RoutineInput({
    required this.weekday,
    required this.wake,
    required this.sleep,
    required this.trainingStart,
    required this.trainingMinutes,
    required this.sessionTitle,
    required this.officeStart,
    required this.officeEnd,
    required this.isOfficeDay,
    required this.proteinTargetG,
    required this.stepGoal,
    this.commuteMinutes = 45,
    this.mealsPerDay = 4,
    this.focusBlocks = true,
    this.rituals = const {},
    this.mealExamples = const [],
  });

  /// ISO weekday, Monday = 1.
  final int weekday;
  final int wake;
  final int sleep;
  final int trainingStart;
  final int trainingMinutes;
  final String sessionTitle;
  final int officeStart;
  final int officeEnd;
  final bool isOfficeDay;
  final int proteinTargetG;
  final int stepGoal;
  final int commuteMinutes;
  final int mealsPerDay;
  final bool focusBlocks;
  final Set<Ritual> rituals;

  /// Eggetarian meal examples, used in order for the meal blocks.
  final List<String> mealExamples;
}

/// Builds the day's timeline. Blocks are sorted by start time; non-office
/// blocks never overlap each other or the office window, and office-only
/// blocks ([RoutineBlock.atOffice]) lie inside it.
List<RoutineBlock> buildRoutine(RoutineInput i) {
  final blocks = <RoutineBlock>[];
  final meals = math.max<int>(3, math.min<int>(5, i.mealsPerDay));
  final perMeal = (i.proteinTargetG / meals).round();
  var mealIndex = 0;
  String? example() => i.mealExamples.isEmpty
      ? null
      : i.mealExamples[mealIndex % i.mealExamples.length];
  RoutineBlock meal(int start, String title, {bool atOffice = false}) {
    final ex = example();
    mealIndex++;
    return RoutineBlock(
      start: start,
      end: start + (atOffice ? 30 : 25),
      kind: RoutineKind.meal,
      title: title,
      detail: ex == null ? '~$perMeal g protein' : '~$perMeal g protein · $ex',
      atOffice: atOffice,
      proteinG: perMeal,
    );
  }

  final sleep = i.sleep <= i.wake ? i.sleep + 1440 : i.sleep;
  final trainEnd = i.trainingStart + i.trainingMinutes;

  blocks.add(
    RoutineBlock(
      start: i.wake,
      end: math.min<int>(i.wake + 15, i.trainingStart),
      kind: RoutineKind.wake,
      title: 'Wake · 500 ml water',
      detail: 'Light, pre-workout snack: banana + black coffee.',
    ),
  );
  if (i.rituals.contains(Ritual.morningBriefing) &&
      i.trainingStart - (i.wake + 15) >= 10) {
    blocks.add(
      RoutineBlock(
        start: i.wake + 15,
        end: math.min<int>(i.wake + 25, i.trainingStart),
        kind: RoutineKind.ritual,
        title: 'Morning briefing',
        detail: 'Today\'s session, targets and top-3 priorities.',
      ),
    );
  }
  blocks.add(
    RoutineBlock(
      start: i.trainingStart,
      end: trainEnd,
      kind: RoutineKind.training,
      title: i.sessionTitle,
    ),
  );
  final breakfast = trainEnd + 15;
  blocks.add(meal(breakfast, 'Post-workout breakfast'));

  if (i.isOfficeDay) {
    final leave = i.officeStart - i.commuteMinutes;
    if (leave - (breakfast + 25) >= 20) {
      blocks.add(
        RoutineBlock(
          start: breakfast + 25,
          end: leave,
          kind: RoutineKind.personal,
          title: 'Prep & personal time',
          detail: 'Pack meals 2–3, shower, plan the day.',
        ),
      );
    }
    blocks.add(
      RoutineBlock(
        start: leave,
        end: i.officeStart,
        kind: RoutineKind.commute,
        title: 'Commute',
      ),
    );
    blocks.add(
      RoutineBlock(
        start: i.officeStart,
        end: i.officeEnd,
        kind: RoutineKind.office,
        title: 'Office',
      ),
    );
    final officeLen = i.officeEnd - i.officeStart;
    final lunch = i.officeStart + math.min<int>(150, officeLen ~/ 3);
    if (i.focusBlocks) {
      blocks.add(
        RoutineBlock(
          start: i.officeStart + 15,
          end: math.min<int>(i.officeStart + 105, lunch),
          kind: RoutineKind.focus,
          title: 'Focus block · priority #1',
          detail: 'Phone on Do Not Disturb.',
          atOffice: true,
        ),
      );
    }
    blocks.add(meal(lunch, 'Lunch', atOffice: true));
    if (i.focusBlocks && lunch + 120 + 90 <= i.officeEnd) {
      blocks.add(
        RoutineBlock(
          start: lunch + 75,
          end: lunch + 165,
          kind: RoutineKind.focus,
          title: 'Focus block · priority #2',
          atOffice: true,
        ),
      );
    }
    if (meals >= 4) {
      final snack = math.min<int>(lunch + 210, i.officeEnd - 40);
      blocks.add(meal(snack, 'Protein snack', atOffice: true));
    }
    final home = i.officeEnd + i.commuteMinutes;
    blocks.add(
      RoutineBlock(
        start: i.officeEnd,
        end: home,
        kind: RoutineKind.commute,
        title: 'Commute home',
        detail: 'Walk where you can — every step counts.',
      ),
    );
    blocks.add(
      RoutineBlock(
        start: home + 10,
        end: home + 45,
        kind: RoutineKind.walk,
        title: 'Evening walk',
        detail: '~3,500 steps toward ${_k(i.stepGoal)}.',
      ),
    );
    blocks.add(meal(home + 60, 'Dinner'));
  } else {
    final walk = breakfast + 60;
    blocks.add(
      RoutineBlock(
        start: breakfast + 25,
        end: walk,
        kind: RoutineKind.personal,
        title: 'Weekly prep',
        detail: 'Groceries, batch-cook dal/soya/paneer, review the week.',
      ),
    );
    blocks.add(
      RoutineBlock(
        start: walk,
        end: walk + 60,
        kind: RoutineKind.walk,
        title: 'Long walk',
        detail: '~6,000 steps toward ${_k(i.stepGoal)}.',
      ),
    );
    blocks.add(meal(13 * 60, 'Lunch'));
    if (meals >= 4) blocks.add(meal(16 * 60 + 30, 'Protein snack'));
    blocks.add(
      const RoutineBlock(
        start: 18 * 60,
        end: 18 * 60 + 30,
        kind: RoutineKind.walk,
        title: 'Evening walk',
        detail: 'Top up steps.',
      ),
    );
    blocks.add(meal(19 * 60 + 45, 'Dinner'));
  }

  // Evening rituals, latest first so they stack before bed.
  final wind = sleep - 45;
  if (meals >= 5) {
    blocks.add(meal(wind - 60, 'Bedtime curd / casein'));
  }
  if (i.rituals.contains(Ritual.moodCheckIn)) {
    blocks.add(
      RoutineBlock(
        start: wind - 15,
        end: wind - 5,
        kind: RoutineKind.ritual,
        title: 'Mood check-in',
      ),
    );
  }
  if (i.rituals.contains(Ritual.eveningReview)) {
    blocks.add(
      RoutineBlock(
        start: wind,
        end: wind + 15,
        kind: RoutineKind.ritual,
        title: 'Evening review',
        detail: 'What went well, set tomorrow\'s top 3.',
      ),
    );
  }
  blocks.add(
    RoutineBlock(
      start: wind + 15,
      end: sleep,
      kind: RoutineKind.windDown,
      title: i.rituals.contains(Ritual.journal)
          ? 'Wind-down · journal'
          : 'Wind-down',
      detail: 'Screens off, lights low.',
    ),
  );
  blocks.add(
    RoutineBlock(
      start: sleep,
      end: math.max<int>(sleep + 1, 1440),
      kind: RoutineKind.sleep,
      title: 'Sleep',
      detail: '${_hours(i.wake + 1440 - sleep)} in bed before next wake.',
    ),
  );

  blocks.sort((a, b) {
    final c = a.start.compareTo(b.start);
    return c != 0 ? c : (a.atOffice ? 1 : 0).compareTo(b.atOffice ? 1 : 0);
  });
  return blocks;
}

String _k(int steps) => '${(steps / 1000).toStringAsFixed(0)}k';
String _hours(int minutes) =>
    '${minutes ~/ 60} h${minutes % 60 == 0 ? '' : ' ${minutes % 60} min'}';

/// The block in progress at [minute], if any (office-internal blocks win).
RoutineBlock? currentBlock(List<RoutineBlock> blocks, int minute) {
  RoutineBlock? hit;
  for (final b in blocks) {
    if (minute >= b.start && minute < b.end) {
      if (hit == null || b.atOffice) hit = b;
    }
  }
  return hit;
}
