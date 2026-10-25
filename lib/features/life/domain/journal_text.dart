/// Local reflection prompts and journal export formatting. Pure Dart.
library;

const journalPrompts = <String>[
  'What went well today, even if it was small?',
  'What drained your energy today, and what restored it?',
  'What is one thing you want to remember about today?',
  'What did your body need today? Did it get it?',
  'What are you looking forward to tomorrow?',
  'What challenged you today and how did you respond?',
  'Who made your day a little better?',
  'What would make tomorrow feel like a good day?',
  'What did you learn about yourself this week?',
  'Where did you show discipline today? Where could you be kinder to yourself?',
  'What is taking up space in your mind right now?',
  'How did training feel today, physically and mentally?',
];

/// Picks a prompt deterministically from a seed (e.g. a day number) so the
/// "next prompt" button cycles predictably.
String promptFor(int seed) =>
    journalPrompts[seed.abs() % journalPrompts.length];

class JournalExportEntry {
  const JournalExportEntry({
    required this.localDate,
    required this.body,
    this.gratitude,
    this.prompt,
  });
  final String localDate;
  final String body;
  final String? gratitude;
  final String? prompt;
}

/// Plain-text export of the user's own journal, newest first.
String formatJournalExport(List<JournalExportEntry> entries) {
  final sorted = [...entries]
    ..sort((a, b) => b.localDate.compareTo(a.localDate));
  final b = StringBuffer('Athlete OS journal export\n');
  b.writeln('${sorted.length} ${sorted.length == 1 ? 'entry' : 'entries'}');
  for (final e in sorted) {
    b
      ..writeln()
      ..writeln('=== ${e.localDate} ===');
    if (e.prompt != null && e.prompt!.trim().isNotEmpty) {
      b.writeln('Prompt: ${e.prompt!.trim()}');
    }
    if (e.body.trim().isNotEmpty) b.writeln(e.body.trim());
    if (e.gratitude != null && e.gratitude!.trim().isNotEmpty) {
      b.writeln('Grateful for: ${e.gratitude!.trim()}');
    }
  }
  return b.toString();
}
