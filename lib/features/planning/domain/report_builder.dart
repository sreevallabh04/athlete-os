/// Deterministic weekly/monthly report builder. Pure: it only aggregates the
/// already-queried [ReportInput]; it never invents values. Every metric that
/// lacks data is reported as unavailable rather than zero.
library;

import '../../../core/time/clock.dart' show LocalDates;
import '../../../core/util/format.dart';
import 'habit_schedule.dart';
import 'metrics.dart';

class ReportTargets {
  const ReportTargets({
    required this.calorieTarget,
    required this.proteinTargetG,
    required this.stepGoal,
    required this.waterGoalMl,
  });
  final int calorieTarget;
  final double proteinTargetG;
  final int stepGoal;
  final int waterGoalMl;
}

class ReportInput {
  const ReportInput({
    required this.kind,
    required this.periodStart,
    required this.periodEnd,
    required this.asOfDate,
    required this.targets,
    this.nutrition = const {},
    this.weights = const [],
    this.steps = const [],
    this.sleep = const [],
    this.cardio = const [],
    this.workouts = const [],
    this.sets = const [],
    this.water = const {},
    this.habits = const [],
    this.habitMarks = const [],
    this.moods = const [],
    this.competitionLine,
  });

  /// weekly | monthly
  final String kind;
  final String periodStart;
  final String periodEnd;

  /// Days after this date are not counted (a period in progress).
  final String asOfDate;
  final ReportTargets targets;
  final Map<String, DayNutrition> nutrition;
  final List<WeightPoint> weights;
  final List<DailyMetric> steps;
  final List<DailyMetric> sleep;
  final List<CardioRecord> cardio;
  final List<WorkoutRecord> workouts;
  final List<StrengthSet> sets;

  /// ml per day, only for days with at least one water log.
  final Map<String, int> water;
  final List<HabitSpec> habits;
  final List<HabitMark> habitMarks;
  final List<MoodPoint> moods;
  final String? competitionLine;

  /// Counted days: periodStart..min(periodEnd, asOfDate).
  List<String> get days {
    final end = periodEnd.compareTo(asOfDate) <= 0 ? periodEnd : asOfDate;
    if (end.compareTo(periodStart) < 0) return const [];
    return LocalDates.range(periodStart, end);
  }
}

class ReportMetric {
  const ReportMetric(this.label, this.value, {this.detail, this.source});
  final String label;
  final String value;
  final String? detail;
  final String? source;

  Map<String, Object?> toJson() => {
    'label': label,
    'value': value,
    if (detail != null) 'detail': detail,
    if (source != null) 'source': source,
  };
  static ReportMetric fromJson(Map<String, Object?> j) => ReportMetric(
    j['label']! as String,
    j['value']! as String,
    detail: j['detail'] as String?,
    source: j['source'] as String?,
  );
}

class ReportSection {
  const ReportSection({
    required this.key,
    required this.title,
    required this.metrics,
    this.note,
    this.available = true,
  });
  final String key;
  final String title;
  final List<ReportMetric> metrics;
  final String? note;
  final bool available;

  Map<String, Object?> toJson() => {
    'key': key,
    'title': title,
    'available': available,
    if (note != null) 'note': note,
    'metrics': [for (final m in metrics) m.toJson()],
  };
  static ReportSection fromJson(Map<String, Object?> j) => ReportSection(
    key: j['key']! as String,
    title: j['title']! as String,
    note: j['note'] as String?,
    available: j['available'] as bool? ?? true,
    metrics: [
      for (final m in (j['metrics'] as List? ?? const []))
        ReportMetric.fromJson((m as Map).cast<String, Object?>()),
    ],
  );
}

class ReportSeries {
  const ReportSeries({
    required this.key,
    required this.title,
    required this.unit,
    required this.source,
    required this.points,
    this.bar = false,
  });
  final String key;
  final String title;
  final String unit;
  final String source;
  final List<SeriesPoint> points;
  final bool bar;

  Map<String, Object?> toJson() => {
    'key': key,
    'title': title,
    'unit': unit,
    'source': source,
    'bar': bar,
    'points': [for (final p in points) p.toJson()],
  };
  static ReportSeries fromJson(Map<String, Object?> j) => ReportSeries(
    key: j['key']! as String,
    title: j['title']! as String,
    unit: j['unit']! as String,
    source: j['source']! as String,
    bar: j['bar'] as bool? ?? false,
    points: [
      for (final p in (j['points'] as List? ?? const []))
        SeriesPoint.fromJson((p as Map).cast<String, Object?>()),
    ],
  );
}

/// A transparent, rule-based insight.
class RuleInsight {
  const RuleInsight({
    required this.title,
    required this.detail,
    required this.rule,
  });
  final String title;
  final String detail;

  /// Plain-language statement of the rule that produced this insight.
  final String rule;

  Map<String, Object?> toJson() => {
    'title': title,
    'detail': detail,
    'rule': rule,
  };
  static RuleInsight fromJson(Map<String, Object?> j) => RuleInsight(
    title: j['title']! as String,
    detail: j['detail']! as String,
    rule: j['rule']! as String,
  );
}

class PeriodReport {
  const PeriodReport({
    required this.kind,
    required this.periodStart,
    required this.periodEnd,
    required this.daysCounted,
    required this.sections,
    required this.numbers,
    required this.series,
    required this.improvement,
    required this.focus,
    this.competitionLine,
  });

  final String kind;
  final String periodStart;
  final String periodEnd;
  final int daysCounted;
  final List<ReportSection> sections;

  /// Raw aggregates (null = no data). Keys are stable, e.g. `nutrition.avgKcal`.
  final Map<String, num?> numbers;
  final List<ReportSeries> series;
  final RuleInsight improvement;
  final RuleInsight focus;
  final String? competitionLine;

  Map<String, Object?> toJson() => {
    'version': 1,
    'kind': kind,
    'periodStart': periodStart,
    'periodEnd': periodEnd,
    'daysCounted': daysCounted,
    'competitionLine': competitionLine,
    'sections': [for (final s in sections) s.toJson()],
    'numbers': numbers,
    'series': [for (final s in series) s.toJson()],
    'improvement': improvement.toJson(),
    'focus': focus.toJson(),
  };

  static PeriodReport fromJson(Map<String, Object?> j) => PeriodReport(
    kind: j['kind']! as String,
    periodStart: j['periodStart']! as String,
    periodEnd: j['periodEnd']! as String,
    daysCounted: (j['daysCounted'] as num?)?.toInt() ?? 0,
    competitionLine: j['competitionLine'] as String?,
    sections: [
      for (final s in (j['sections'] as List? ?? const []))
        ReportSection.fromJson((s as Map).cast<String, Object?>()),
    ],
    numbers: ((j['numbers'] as Map?) ?? const {}).map(
      (k, v) => MapEntry(k as String, v as num?),
    ),
    series: [
      for (final s in (j['series'] as List? ?? const []))
        ReportSeries.fromJson((s as Map).cast<String, Object?>()),
    ],
    improvement: RuleInsight.fromJson(
      (j['improvement']! as Map).cast<String, Object?>(),
    ),
    focus: RuleInsight.fromJson((j['focus']! as Map).cast<String, Object?>()),
  );
}

abstract final class ReportBuilder {
  /// Builds the report for [input]. [previous] (the preceding period) is used
  /// only for the rule-based "most important improvement".
  static PeriodReport build(ReportInput input, {ReportInput? previous}) {
    final n = computeNumbers(input);
    final prev = previous == null ? null : computeNumbers(previous);
    final days = input.days;
    final t = input.targets;
    final sections = <ReportSection>[];
    final series = <ReportSeries>[];
    String pct(num? v) => v == null ? '—' : '${v.round()}%';

    // Nutrition
    final logged = n['nutrition.loggedDays']!.toInt();
    sections.add(
      logged == 0
          ? const ReportSection(
              key: 'nutrition',
              title: 'Nutrition',
              available: false,
              metrics: [],
              note: 'No food logged in this period.',
            )
          : ReportSection(
              key: 'nutrition',
              title: 'Nutrition',
              note:
                  'Averages use logged days only ($logged of ${days.length} '
                  'days). Unlogged days are not counted as zero.',
              metrics: [
                ReportMetric(
                  'Avg calories',
                  Fmt.kcal(n['nutrition.avgKcal']!),
                  detail: 'Target ${Fmt.kcal(t.calorieTarget)}',
                  source: 'Food log',
                ),
                ReportMetric(
                  'Avg protein',
                  Fmt.grams(n['nutrition.avgProteinG']!.round()),
                  detail: 'Target ${Fmt.grams(t.proteinTargetG.round())}',
                  source: 'Food log',
                ),
                ReportMetric(
                  'Avg carbs / fat',
                  '${Fmt.grams(n['nutrition.avgCarbsG']!.round())} / '
                      '${Fmt.grams(n['nutrition.avgFatG']!.round())}',
                  source: 'Food log',
                ),
                ReportMetric(
                  'Protein target hit',
                  '${n['nutrition.proteinDays']} of $logged logged '
                      '${logged == 1 ? 'day' : 'days'}',
                  detail: pct(n['nutrition.proteinAdherencePct']),
                ),
                ReportMetric(
                  'Calories within ±10%',
                  '${n['nutrition.calorieDays']} of $logged logged '
                      '${logged == 1 ? 'day' : 'days'}',
                ),
              ],
            ),
    );
    if (logged > 0) {
      series.add(
        ReportSeries(
          key: 'kcal',
          title: 'Calories per logged day',
          unit: 'kcal',
          source: 'Food log',
          bar: true,
          points: [
            for (final d in days)
              if (input.nutrition[d]?.logged ?? false)
                SeriesPoint(d, input.nutrition[d]!.kcal),
          ],
        ),
      );
      series.add(
        ReportSeries(
          key: 'protein',
          title: 'Protein per logged day',
          unit: 'g',
          source: 'Food log',
          bar: true,
          points: [
            for (final d in days)
              if (input.nutrition[d]?.logged ?? false)
                SeriesPoint(d, input.nutrition[d]!.proteinG),
          ],
        ),
      );
    }

    // Body weight
    final weights = input.weights.where((w) => days.contains(w.date)).toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    if (weights.isEmpty) {
      sections.add(
        const ReportSection(
          key: 'weight',
          title: 'Body weight',
          available: false,
          metrics: [],
          note: 'No weight entries in this period.',
        ),
      );
    } else {
      final ma = trailingMovingAverage(weights);
      final src = sourcesLabel(weights.map((w) => w.origin));
      sections.add(
        ReportSection(
          key: 'weight',
          title: 'Body weight',
          note:
              'Short-term scale changes mostly reflect water, food and '
              'glycogen — they are not fat or muscle changes. Watch the '
              '7-day average over several weeks.',
          metrics: [
            ReportMetric(
              'First → last',
              '${weights.first.kg.toStringAsFixed(1)} → '
                  '${weights.last.kg.toStringAsFixed(1)} kg',
              detail:
                  '${weights.length} reading${weights.length == 1 ? '' : 's'}',
              source: src,
            ),
            ReportMetric(
              '7-day average (end)',
              '${ma.last.value.toStringAsFixed(1)} kg',
              source: src,
            ),
          ],
        ),
      );
      series.add(
        ReportSeries(
          key: 'weight',
          title: 'Body weight (7-day average)',
          unit: 'kg',
          source: src,
          points: ma,
        ),
      );
    }

    // Steps
    final steps = preferHealthConnect(
      input.steps.where((s) => days.contains(s.date)),
    );
    if (steps.isEmpty) {
      sections.add(
        const ReportSection(
          key: 'steps',
          title: 'Steps',
          available: false,
          metrics: [],
          note: 'No step data in this period.',
        ),
      );
    } else {
      final src = sourcesLabel(steps.values.map((s) => s.origin));
      sections.add(
        ReportSection(
          key: 'steps',
          title: 'Steps',
          metrics: [
            ReportMetric(
              'Daily average',
              Fmt.integer(n['steps.avg']!),
              detail: 'Over ${steps.length} days with data',
              source: src,
            ),
            ReportMetric(
              'Goal hit',
              '${n['steps.goalDays']} of ${steps.length} days',
              detail: 'Goal ${Fmt.integer(t.stepGoal)}',
              source: src,
            ),
          ],
        ),
      );
      series.add(
        ReportSeries(
          key: 'steps',
          title: 'Steps per day',
          unit: 'steps',
          source: src,
          bar: true,
          points: [
            for (final d in days)
              if (steps[d] != null) SeriesPoint(d, steps[d]!.value),
          ],
        ),
      );
    }

    // Running
    final cardio = input.cardio.where((c) => days.contains(c.date)).toList();
    final runs = summarizeRuns(cardio);
    if (runs.count == 0) {
      sections.add(
        ReportSection(
          key: 'running',
          title: 'Running',
          available: false,
          metrics: const [],
          note: runs.excludedNonRuns > 0
              ? 'No runs this period (${runs.excludedNonRuns} other cardio '
                    'activities are not counted as running).'
              : 'No runs recorded in this period.',
        ),
      );
    } else {
      final src = sourcesLabel(runs.sources);
      sections.add(
        ReportSection(
          key: 'running',
          title: 'Running',
          note: runs.excludedNonRuns > 0
              ? 'Walks, rides and other cardio (${runs.excludedNonRuns}) are '
                    'excluded so pace is not mixed across sports.'
              : null,
          metrics: [
            ReportMetric('Runs', '${runs.count}', source: src),
            ReportMetric('Distance', Fmt.km(runs.distanceM), source: src),
            ReportMetric(
              'Average pace',
              runs.avgPaceSecPerKm == null
                  ? 'Unavailable'
                  : Fmt.pace(runs.avgPaceSecPerKm!),
              detail: 'Moving time ÷ distance, runs with both values',
              source: src,
            ),
          ],
        ),
      );
      final perDay = <String, double>{};
      for (final r in cardio.where((c) => c.isRun)) {
        perDay.update(
          r.date,
          (v) => v + (r.distanceM ?? 0) / 1000,
          ifAbsent: () => (r.distanceM ?? 0) / 1000,
        );
      }
      series.add(
        ReportSeries(
          key: 'run_km',
          title: 'Running distance',
          unit: 'km',
          source: src,
          bar: true,
          points: [
            for (final d in days)
              if (perDay[d] != null) SeriesPoint(d, perDay[d]!),
          ],
        ),
      );
    }

    // Strength
    final workouts = input.workouts
        .where((w) => days.contains(w.date))
        .toList();
    final sets = input.sets.where((s) => days.contains(s.date)).toList();
    if (workouts.isEmpty) {
      sections.add(
        const ReportSection(
          key: 'strength',
          title: 'Strength training',
          available: false,
          metrics: [],
          note: 'No workouts recorded in this period.',
        ),
      );
    } else {
      final src = sourcesLabel(workouts.map((w) => w.source));
      final top = topExerciseProgress(sets);
      sections.add(
        ReportSection(
          key: 'strength',
          title: 'Strength training',
          note: 'Volume = weight × reps of working sets (warm-ups excluded).',
          metrics: [
            ReportMetric('Workouts', '${workouts.length}', source: src),
            ReportMetric(
              'Training frequency',
              '${n['strength.perWeek']!.toStringAsFixed(1)} / week',
            ),
            ReportMetric(
              'Total volume',
              '${Fmt.integer(n['strength.volumeKg']!)} kg',
              source: src,
            ),
            ReportMetric(
              'Top exercise progress',
              top == null
                  ? 'Not enough repeat sessions'
                  : '${top.exercise}: ${Fmt.oneDp(top.firstTopKg)} → '
                        '${Fmt.oneDp(top.lastTopKg)} kg',
              detail: top == null
                  ? null
                  : 'Top working set, ${top.sessions} sessions',
            ),
          ],
        ),
      );
    }

    // Hydration
    final waterDays = days.where((d) => (input.water[d] ?? 0) > 0).length;
    sections.add(
      waterDays == 0
          ? const ReportSection(
              key: 'hydration',
              title: 'Hydration',
              available: false,
              metrics: [],
              note: 'No water logged in this period.',
            )
          : ReportSection(
              key: 'hydration',
              title: 'Hydration',
              metrics: [
                ReportMetric(
                  'Goal reached',
                  '${n['hydration.goalDays']} of ${days.length} days',
                  detail:
                      'Goal ${Fmt.ml(t.waterGoalMl)} · logged on '
                      '$waterDays days',
                  source: 'Water log',
                ),
                ReportMetric(
                  'Avg on logged days',
                  Fmt.ml(n['hydration.avgMl']!),
                  source: 'Water log',
                ),
              ],
            ),
    );

    // Habits
    final habitPct = n['habits.completionPct'];
    sections.add(
      habitPct == null
          ? const ReportSection(
              key: 'habits',
              title: 'Habits',
              available: false,
              metrics: [],
              note: 'No active habits scheduled in this period.',
            )
          : ReportSection(
              key: 'habits',
              title: 'Habits',
              metrics: [
                ReportMetric(
                  'Completion',
                  pct(habitPct),
                  detail:
                      '${n['habits.completed']} of ${n['habits.expected']} '
                      'scheduled check-ins',
                ),
              ],
            ),
    );

    // Mood & sleep
    final wellbeing = <ReportMetric>[
      if (n['mood.avg'] != null)
        ReportMetric(
          'Average mood',
          '${n['mood.avg']!.toStringAsFixed(1)} / 5',
          detail: '${n['mood.entries']} check-ins',
          source: 'Mood log',
        ),
      if (n['sleep.avgMinutes'] != null)
        ReportMetric(
          'Average sleep',
          _hm(n['sleep.avgMinutes']!.round()),
          detail: '${n['sleep.days']} nights with data',
          source: sourcesLabel(
            preferHealthConnect(input.sleep.where((s) => days.contains(s.date)))
                .values
                .map((s) => s.origin),
          ),
        ),
    ];
    sections.add(
      ReportSection(
        key: 'wellbeing',
        title: 'Mood & sleep',
        available: wellbeing.isNotEmpty,
        metrics: wellbeing,
        note: wellbeing.isEmpty ? 'No mood or sleep data.' : null,
      ),
    );

    return PeriodReport(
      kind: input.kind,
      periodStart: input.periodStart,
      periodEnd: input.periodEnd,
      daysCounted: days.length,
      sections: sections,
      numbers: n,
      series: series,
      improvement: _improvement(input.kind, n, prev),
      focus: _focus(n, days.length),
      competitionLine: input.competitionLine,
    );
  }

  /// Raw aggregates for [input] (null = no data for that metric).
  static Map<String, num?> computeNumbers(ReportInput input) {
    final days = input.days;
    final t = input.targets;
    final out = <String, num?>{'days': days.length};

    final adherence = nutritionAdherence(
      input.nutrition,
      days,
      calorieTarget: t.calorieTarget,
      proteinTargetG: t.proteinTargetG,
    );
    final loggedDays = [
      for (final d in days)
        if (input.nutrition[d]?.logged ?? false) input.nutrition[d]!,
    ];
    out['nutrition.loggedDays'] = adherence.loggedDays;
    out['nutrition.avgKcal'] = mean(loggedDays.map((d) => d.kcal));
    out['nutrition.avgProteinG'] = mean(loggedDays.map((d) => d.proteinG));
    out['nutrition.avgCarbsG'] = mean(loggedDays.map((d) => d.carbsG));
    out['nutrition.avgFatG'] = mean(loggedDays.map((d) => d.fatG));
    out['nutrition.proteinDays'] = adherence.proteinDays;
    out['nutrition.calorieDays'] = adherence.calorieDays;
    out['nutrition.proteinAdherencePct'] = adherence.loggedDays == 0
        ? null
        : adherence.proteinDays * 100 / adherence.loggedDays;

    final weights = input.weights.where((w) => days.contains(w.date)).toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    out['weight.first'] = weights.isEmpty ? null : weights.first.kg;
    out['weight.last'] = weights.isEmpty ? null : weights.last.kg;
    out['weight.readings'] = weights.length;

    final steps = preferHealthConnect(
      input.steps.where((s) => days.contains(s.date)),
    );
    out['steps.days'] = steps.length;
    out['steps.avg'] = mean(steps.values.map((s) => s.value));
    out['steps.goalDays'] = steps.values
        .where((s) => s.value >= t.stepGoal)
        .length;
    out['steps.goalPct'] = steps.isEmpty
        ? null
        : out['steps.goalDays']! * 100 / steps.length;

    final runs = summarizeRuns(
      input.cardio.where((c) => days.contains(c.date)),
    );
    out['run.count'] = runs.count;
    out['run.distanceKm'] = runs.distanceM / 1000;
    out['run.avgPaceSecPerKm'] = runs.avgPaceSecPerKm;

    final workouts = input.workouts.where((w) => days.contains(w.date));
    final sets = input.sets.where((s) => days.contains(s.date));
    out['strength.workouts'] = workouts.length;
    out['strength.volumeKg'] = totalVolume(sets);
    out['strength.perWeek'] = days.isEmpty
        ? 0
        : workouts.length / (days.length / 7);

    final waterLogged = days.where((d) => (input.water[d] ?? 0) > 0).toList();
    out['hydration.loggedDays'] = waterLogged.length;
    out['hydration.goalDays'] = days
        .where((d) => (input.water[d] ?? 0) >= t.waterGoalMl)
        .length;
    out['hydration.adherencePct'] = waterLogged.isEmpty || days.isEmpty
        ? null
        : out['hydration.goalDays']! * 100 / days.length;
    out['hydration.avgMl'] = mean(waterLogged.map((d) => input.water[d]!));

    final habits = habitCompletion(input.habits, days, input.habitMarks);
    out['habits.expected'] = habits.expected;
    out['habits.completed'] = habits.completed;
    out['habits.completionPct'] = habits.expected == 0
        ? null
        : habits.completed * 100 / habits.expected;

    final moods = input.moods.where((m) => days.contains(m.date)).toList();
    out['mood.entries'] = moods.length;
    out['mood.avg'] = mean(moods.map((m) => m.mood));

    final sleep = preferHealthConnect(
      input.sleep.where((s) => days.contains(s.date)),
    );
    out['sleep.days'] = sleep.length;
    out['sleep.avgMinutes'] = mean(sleep.values.map((s) => s.value));
    return out;
  }

  static const _comparable = <String, String>{
    'nutrition.proteinAdherencePct': 'Protein-target adherence',
    'steps.avg': 'Average daily steps',
    'run.distanceKm': 'Running distance',
    'strength.workouts': 'Workouts completed',
    'habits.completionPct': 'Habit completion',
    'hydration.adherencePct': 'Hydration goal days',
    'nutrition.loggedDays': 'Days with food logged',
  };

  static RuleInsight _improvement(
    String kind,
    Map<String, num?> cur,
    Map<String, num?>? prev,
  ) {
    final period = kind == 'monthly' ? 'month' : 'week';
    final rule =
        'Rule-based: the largest relative increase versus the previous '
        '$period among metrics that have data in both periods.';
    if (prev == null) {
      return RuleInsight(
        title: 'Not enough history yet',
        detail: 'A comparison needs data from the previous $period.',
        rule: rule,
      );
    }
    String? bestKey;
    var bestChange = 0.0;
    for (final key in _comparable.keys) {
      final c = cur[key];
      final p = prev[key];
      if (c == null || p == null || p <= 0) continue;
      final change = (c - p) / p;
      if (change > bestChange + 1e-9) {
        bestChange = change.toDouble();
        bestKey = key;
      }
    }
    if (bestKey == null) {
      return RuleInsight(
        title: 'No clear improvement this $period',
        detail:
            'None of the tracked metrics rose compared with the previous '
            '$period (or there was not enough data to compare).',
        rule: rule,
      );
    }
    String f(num v) => switch (bestKey) {
      'steps.avg' => Fmt.integer(v),
      'run.distanceKm' => '${v.toStringAsFixed(1)} km',
      'nutrition.proteinAdherencePct' ||
      'habits.completionPct' ||
      'hydration.adherencePct' => '${v.round()}%',
      _ => '${v.round()}',
    };
    return RuleInsight(
      title: _comparable[bestKey]!,
      detail:
          '${f(prev[bestKey]!)} → ${f(cur[bestKey]!)} '
          '(+${(bestChange * 100).round()}%)',
      rule: rule,
    );
  }

  static RuleInsight _focus(Map<String, num?> n, int days) {
    if (days == 0) {
      return const RuleInsight(
        title: 'No days to evaluate yet',
        detail: 'This period has not started.',
        rule: 'Rule-based: needs at least one counted day.',
      );
    }
    final logged = n['nutrition.loggedDays']!;
    if (logged < days * 0.6) {
      return RuleInsight(
        title: 'Log meals consistently',
        detail:
            'Food was logged on $logged of $days days. Consistent logging '
            'makes every other nutrition number trustworthy.',
        rule: 'Rule 1: fewer than 60% of days had food logged.',
      );
    }
    final protein = n['nutrition.proteinAdherencePct'];
    if (protein != null && protein < 70) {
      return RuleInsight(
        title: 'Hit your protein target more often',
        detail: 'Protein target reached on ${protein.round()}% of logged days.',
        rule: 'Rule 2: protein target met on fewer than 70% of logged days.',
      );
    }
    final perWeek = n['strength.perWeek']!;
    if (days >= 7 && perWeek < 3) {
      return RuleInsight(
        title: 'Train more consistently',
        detail:
            '${perWeek.toStringAsFixed(1)} workouts per week recorded. '
            'Aim for a sustainable 3+ sessions.',
        rule: 'Rule 3: fewer than 3 recorded workouts per week.',
      );
    }
    final stepPct = n['steps.goalPct'];
    if (stepPct != null && stepPct < 50) {
      return RuleInsight(
        title: 'Move more on low-step days',
        detail: 'Step goal reached on ${stepPct.round()}% of days with data.',
        rule: 'Rule 4: step goal met on fewer than 50% of days with data.',
      );
    }
    final water = n['hydration.adherencePct'];
    if (water != null && water < 50) {
      return RuleInsight(
        title: 'Drink to your water goal',
        detail: 'Water goal reached on ${water.round()}% of days.',
        rule: 'Rule 5: water goal met on fewer than 50% of days.',
      );
    }
    final habits = n['habits.completionPct'];
    if (habits != null && habits < 60) {
      return RuleInsight(
        title: 'Simplify and protect your habits',
        detail: '${habits.round()}% of scheduled habits completed.',
        rule: 'Rule 6: habit completion below 60%.',
      );
    }
    return const RuleInsight(
      title: 'Keep the current routine',
      detail: 'No rule flagged a gap — maintain what is working.',
      rule: 'Rules 1–6 did not trigger.',
    );
  }

  static String _hm(int minutes) => '${minutes ~/ 60} h ${minutes % 60} min';
}
