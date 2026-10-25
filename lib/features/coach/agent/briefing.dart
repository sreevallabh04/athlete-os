import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:intl/intl.dart';

import '../../../core/time/clock.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../assistant/application/providers.dart'
    show briefingServiceProvider;
import '../../assistant/domain/briefing_builder.dart';
import '../../onboarding/application/persona_providers.dart';
import '../../onboarding/domain/calibration.dart' show hhmm;
import '../../onboarding/domain/daily_routine.dart';
import '../../onboarding/domain/training_program.dart';

/// "Brief me" (morning) and "Review my day" (evening).
enum BriefingMode {
  morning,
  evening;

  String get command => this == morning ? 'Brief me' : 'Review my day';
}

/// Evening from 16:00 until 04:00, morning otherwise.
BriefingMode briefingModeFor(DateTime now) => now.hour >= 16 || now.hour < 4
    ? BriefingMode.evening
    : BriefingMode.morning;

/// Everything a briefing needs. Unknown values stay null and are reported
/// honestly ("no data"), never as zero.
class CoachBriefingInputs {
  const CoachBriefingInputs({
    required this.now,
    this.name,
    this.lines = const [],
    this.session,
    this.tomorrow,
    this.routine,
  });

  final DateTime now;
  final String? name;

  /// Deterministic status lines (steps, calories, protein, water, calendar,
  /// drafts, unanswered, habits) from the assistant's [BriefingBuilder].
  final List<BriefingLine> lines;
  final PlannedSession? session;
  final PlannedSession? tomorrow;
  final List<RoutineBlock>? routine;
}

String _sessionLine(PlannedSession s) {
  final d = s.day;
  if (d.kind == SessionKind.recovery) {
    return '${d.title} — recovery, ${d.minutes} min';
  }
  final deload = s.isDeload ? ' · deload week' : '';
  final lighter = s.lighter != null
      ? ' (readiness is low — a lighter version is ready)'
      : '';
  return '**${d.title}** · ${d.focus}, ${d.minutes} min$deload$lighter';
}

String _label(BriefingKind k) => switch (k) {
  BriefingKind.steps => 'Steps',
  BriefingKind.calories => 'Calories',
  BriefingKind.protein => 'Protein',
  BriefingKind.water => 'Water',
  BriefingKind.calendar => 'Calendar',
  BriefingKind.drafts => 'Replies',
  BriefingKind.unanswered => 'Messages',
  BriefingKind.habits => 'Habits',
};

/// "Steps: …" unless the line already names its subject.
String _line(BriefingLine l) {
  final label = _label(l.kind);
  final text = _boldLead(l.text);
  final subject = switch (l.kind) {
    BriefingKind.drafts => 'repl',
    BriefingKind.unanswered => 'unanswered',
    _ => label.toLowerCase(),
  };
  return l.text.toLowerCase().contains(subject) ? text : '$label: $text';
}

/// Lines that are tasks (calendar/unanswered status lines are not).
bool _isTask(BriefingLine l) =>
    l.kind != BriefingKind.calendar && l.kind != BriefingKind.unanswered;

/// Bolds the leading number of a line ("8,000 steps to go" → "**8,000**…").
String _boldLead(String s) {
  final m = RegExp(r'^([\d.,]+(?:\s?(?:kcal|g|ml|L|steps)\b)?)').firstMatch(s);
  if (m == null) return s;
  return '**${m.group(1)}**${s.substring(m.end)}';
}

/// Deterministic briefing text (markdown-lite). Pure; unit-tested.
String composeBriefing(BriefingMode mode, CoachBriefingInputs i) {
  final name = (i.name ?? '').trim();
  final who = name.isEmpty ? '' : ', $name';
  final day = DateFormat('EEEE d MMMM').format(i.now);
  final b = StringBuffer();
  final open = i.lines.where((l) => !l.done).toList();
  final done = i.lines.where((l) => l.done).toList();

  if (mode == BriefingMode.morning) {
    final greet = i.now.hour < 12 ? 'Good morning' : 'Good afternoon';
    b.writeln('$greet$who. Your briefing for $day.');
    b.writeln();
    if (i.session != null) {
      b.writeln('- Training: ${_sessionLine(i.session!)}');
    } else {
      b.writeln('- Training: no programme yet — calibrate in Train.');
    }
    for (final l in i.lines) {
      b.writeln('- ${_line(l)}${l.done ? ' ✓' : ''}');
    }
    final routine = i.routine;
    if (routine != null && routine.isNotEmpty) {
      final minute = i.now.hour * 60 + i.now.minute;
      final next = routine.where((r) => r.start >= minute).take(2).toList();
      if (next.isNotEmpty) {
        b.writeln(
          '- Next up: '
          '${next.map((r) => '${hhmm(r.start)} ${r.title}').join(' · ')}',
        );
      }
    }
    b.writeln();
    final tasks = open.where(_isTask).length;
    b.write(
      tasks == 0
          ? 'Everything is on track. A rare and welcome state of affairs.'
          : tasks == 1
          ? 'One item needs your attention today.'
          : '$tasks items need your attention today.',
    );
  } else {
    b.writeln('Evening review$who — $day.');
    b.writeln();
    if (done.isNotEmpty) {
      for (final l in done) {
        b.writeln('- ✓ ${_line(l)}');
      }
    }
    for (final l in open) {
      b.writeln('- ${_line(l)}');
    }
    if (i.lines.isEmpty) {
      b.writeln('- No data logged today yet.');
    }
    if (i.tomorrow != null) {
      b.writeln('- Tomorrow: ${_sessionLine(i.tomorrow!)}');
    }
    b.writeln();
    final total = i.lines.where(_isTask).length;
    final closed = done.where(_isTask).length;
    final remaining = open.where(_isTask).length;
    b.write(
      total == 0
          ? 'Log a meal or sync steps and I can review it properly.'
          : closed == total
          ? 'A clean sweep. Rest well.'
          : '$closed of $total closed. '
                '${remaining == 1 ? 'One item' : '$remaining items'} '
                'still open before bed.',
    );
  }
  return b.toString().trim();
}

/// System prompt for the optional AI polish. The model may only rephrase:
/// numbers and facts must stay exactly as given.
String briefingPolishPrompt(String persona) =>
    '${persona.trim().isEmpty ? 'You are a calm personal coach.' : persona.trim()}\n\n'
    'Rewrite the briefing below in your voice for the user. Rules: use ONLY '
    'the facts given; keep every number, unit, time and name exactly; do not '
    'add advice that needs data you were not given; at most 110 words; '
    'one opening sentence, then "- " bullets with **bold** key numbers; '
    'no tables; no medical claims.';

/// Gathers [CoachBriefingInputs] from the app's providers. Every source is
/// bounded and failure-tolerant.
Future<CoachBriefingInputs> gatherBriefingInputs(Ref ref) async {
  final now = ref.read(clockProvider).now();
  final today = LocalDates.key(now);
  final tomorrowKey = LocalDates.key(now.add(const Duration(days: 1)));
  Future<T?> safe<T>(Future<T?> Function() f) async {
    try {
      return await f().timeout(const Duration(seconds: 6));
    } catch (_) {
      return null;
    }
  }

  // A bare `read(x.future)` never resolves for an unlistened stream
  // provider; hold a subscription while waiting.
  Future<T> listened<T>(ProviderListenable<Future<T>> p) async {
    final sub = ref.listen(p, (_, _) {});
    try {
      return await sub.read();
    } finally {
      sub.close();
    }
  }

  final service = ref.read(briefingServiceProvider);
  final inputs = await safe(service.gather);
  final lines = inputs == null
      ? const <BriefingLine>[]
      : service.builder.build(inputs);
  final profile = await safe(() => ref.read(profileRepositoryProvider).get());
  final session = await safe(
    () => listened(plannedSessionProvider(today).future),
  );
  final tomorrow = await safe(
    () => listened(plannedSessionProvider(tomorrowKey).future),
  );
  final calibration = await safe(() => listened(calibrationProvider.future));
  List<RoutineBlock>? routine;
  if (calibration != null) {
    try {
      routine = routineFor(
        a: calibration,
        date: today,
        proteinTargetG: profile?.proteinTargetG.round() ?? 170,
        session: session,
      );
    } catch (_) {}
  }
  return CoachBriefingInputs(
    now: now,
    name: profile?.displayName,
    lines: lines,
    session: session,
    tomorrow: tomorrow,
    routine: routine,
  );
}
