import '../../../core/contracts/calendar_reader.dart';
import '../../../core/util/format.dart';

enum BriefingKind {
  steps,
  calories,
  protein,
  water,
  calendar,
  drafts,
  unanswered,
  habits,
}

class BriefingLine {
  const BriefingLine(this.kind, this.text, {this.done = false, this.note});
  final BriefingKind kind;
  final String text;

  /// Goal already met.
  final bool done;

  /// Small caveat, e.g. "heuristic" or "calendar not connected".
  final String? note;
}

/// A conversation that may still need an answer (heuristic: only the
/// notifications we saw are known).
class UnansweredConversation {
  const UnansweredConversation({
    required this.title,
    required this.appLabel,
    required this.lastAt,
  });
  final String title;
  final String appLabel;
  final DateTime lastAt;
}

/// Everything the briefing needs, gathered from existing providers/DB. Null
/// means "unknown" and is reported honestly rather than as zero.
class BriefingInputs {
  const BriefingInputs({
    required this.now,
    this.steps,
    this.stepGoal,
    this.caloriesConsumed,
    this.calorieTarget,
    this.proteinConsumed,
    this.proteinTarget,
    this.waterMl,
    this.waterGoalMl,
    this.calendar,
    this.pendingDrafts = 0,
    this.unanswered = const [],
    this.habitsRemaining,
    this.habitsDue,
  });

  final DateTime now;
  final int? steps;
  final int? stepGoal;
  final double? caloriesConsumed;
  final double? calorieTarget;
  final double? proteinConsumed;
  final double? proteinTarget;
  final int? waterMl;
  final int? waterGoalMl;

  /// Remaining events today (null = not checked).
  final CalendarReadResult? calendar;
  final int pendingDrafts;
  final List<UnansweredConversation> unanswered;
  final int? habitsRemaining;
  final int? habitsDue;
}

/// Deterministic briefing lines. No AI, no invented numbers.
class BriefingBuilder {
  const BriefingBuilder();

  List<BriefingLine> build(BriefingInputs i) {
    final out = <BriefingLine>[];

    final goal = i.stepGoal;
    if (i.steps == null) {
      out.add(
        const BriefingLine(
          BriefingKind.steps,
          'Steps: no data yet today',
          note: 'Connect Health Connect or log steps manually',
        ),
      );
    } else if (goal != null && goal > 0) {
      final left = goal - i.steps!;
      out.add(
        left <= 0
            ? BriefingLine(
                BriefingKind.steps,
                'Step goal reached (${Fmt.integer(i.steps!)})',
                done: true,
              )
            : BriefingLine(
                BriefingKind.steps,
                '${Fmt.integer(left)} steps to go '
                '(${Fmt.integer(i.steps!)} of ${Fmt.integer(goal)})',
              ),
      );
    }

    if (i.calorieTarget != null && i.caloriesConsumed != null) {
      final left = i.calorieTarget! - i.caloriesConsumed!;
      out.add(
        left >= 0
            ? BriefingLine(
                BriefingKind.calories,
                '${Fmt.kcal(left)} remaining '
                '(${Fmt.kcal(i.caloriesConsumed!)} logged)',
                done: left == 0,
              )
            : BriefingLine(
                BriefingKind.calories,
                '${Fmt.kcal(-left)} over your calorie target',
              ),
      );
    }
    if (i.proteinTarget != null && i.proteinConsumed != null) {
      final left = i.proteinTarget! - i.proteinConsumed!;
      out.add(
        left > 0
            ? BriefingLine(
                BriefingKind.protein,
                '${Fmt.grams(left)} protein remaining',
              )
            : const BriefingLine(
                BriefingKind.protein,
                'Protein target reached',
                done: true,
              ),
      );
    }
    if (i.waterGoalMl != null && i.waterMl != null) {
      final left = i.waterGoalMl! - i.waterMl!;
      out.add(
        left > 0
            ? BriefingLine(
                BriefingKind.water,
                '${Fmt.ml(left)} water to go (${Fmt.ml(i.waterMl!)} so far)',
              )
            : const BriefingLine(
                BriefingKind.water,
                'Water goal reached',
                done: true,
              ),
      );
    }

    final cal = i.calendar;
    if (cal == null || !cal.connected) {
      out.add(
        const BriefingLine(
          BriefingKind.calendar,
          'Calendar not connected',
          note: 'Connect Google Calendar to see upcoming events',
        ),
      );
    } else if (cal.error != null) {
      out.add(
        const BriefingLine(
          BriefingKind.calendar,
          'Calendar unavailable right now',
        ),
      );
    } else {
      final upcoming = cal.events.where((e) => e.end.isAfter(i.now)).toList()
        ..sort((a, b) => a.start.compareTo(b.start));
      if (upcoming.isEmpty) {
        out.add(
          const BriefingLine(
            BriefingKind.calendar,
            'No more events today',
            done: true,
          ),
        );
      } else {
        final next = upcoming
            .take(2)
            .map(
              (e) => e.allDay
                  ? '${e.title} (all day)'
                  : '${Fmt.time(e.start)} ${e.title}',
            );
        out.add(
          BriefingLine(
            BriefingKind.calendar,
            'Next: ${next.join(' · ')}'
            '${upcoming.length > 2 ? ' (+${upcoming.length - 2} more)' : ''}',
          ),
        );
      }
    }

    if (i.pendingDrafts > 0) {
      out.add(
        BriefingLine(
          BriefingKind.drafts,
          i.pendingDrafts == 1
              ? '1 reply waiting for you'
              : '${i.pendingDrafts} replies waiting for you',
        ),
      );
    }
    if (i.unanswered.isNotEmpty) {
      final names = i.unanswered.take(3).map((u) => u.title).join(', ');
      out.add(
        BriefingLine(
          BriefingKind.unanswered,
          'Possibly unanswered: $names'
          '${i.unanswered.length > 3 ? ' +${i.unanswered.length - 3}' : ''}',
          note: 'Heuristic — based only on notifications this phone saw',
        ),
      );
    }

    if (i.habitsDue != null && i.habitsDue! > 0) {
      final r = i.habitsRemaining ?? 0;
      out.add(
        r == 0
            ? const BriefingLine(
                BriefingKind.habits,
                'All habits done today',
                done: true,
              )
            : BriefingLine(
                BriefingKind.habits,
                r == 1 ? '1 habit left today' : '$r habits left today',
              ),
      );
    }
    return out;
  }

  /// Short notification body (first lines only).
  String notificationBody(List<BriefingLine> lines, {int max = 5}) =>
      lines.where((l) => !l.done).take(max).map((l) => l.text).join('\n');
}
