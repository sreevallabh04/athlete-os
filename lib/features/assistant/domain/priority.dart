import 'sensitivity_classifier.dart';

/// Time-sensitivity heuristics for the "Priorities" list. Labelled as a
/// heuristic in the UI; never used for automation decisions.
class PriorityHint {
  const PriorityHint(this.score, this.reasons);
  final int score;
  final List<String> reasons;
  bool get isPriority => score >= 2;
}

final _urgent = RegExp(
  r'\b(urgent|asap|immediately|right now|emergency|important)\b',
  caseSensitive: false,
);
final _today = RegExp(
  r'\b(today|tonight|this (morning|afternoon|evening)|in \d+ ?(min|mins|minutes|hours?))\b',
  caseSensitive: false,
);
final _call = RegExp(
  r'\b(call me|ring me|pick up|where are you|are you (there|ok|okay)|running late)\b',
  caseSensitive: false,
);

PriorityHint priorityOf({
  required String text,
  required Set<SensitivityFlag> flags,
  required DateTime postedAt,
  required DateTime now,
}) {
  var score = 0;
  final reasons = <String>[];
  if (flags.contains(SensitivityFlag.crisis)) {
    score += 3;
    reasons.add('Possible emergency');
  }
  if (_urgent.hasMatch(text)) {
    score += 2;
    reasons.add('Marked urgent');
  }
  if (_call.hasMatch(text)) {
    score += 2;
    reasons.add('Asks you to respond');
  }
  if (_today.hasMatch(text)) {
    score += 1;
    reasons.add('Mentions today');
  }
  if (text.contains('?')) {
    score += 1;
    reasons.add('Question');
  }
  if (now.difference(postedAt) < const Duration(minutes: 30)) score += 1;
  return PriorityHint(score, reasons);
}
