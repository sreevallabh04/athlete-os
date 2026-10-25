import 'dart:convert';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:intl/intl.dart';

import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/settings_repository.dart';
import '../tools/life_tools.dart' show activeRestrictions;
import '../tools/nutrition_tools.dart' show loadProfile;

/// Inputs for the system prompt. Deliberately small: no history, no logs —
/// the model fetches facts through tools.
class SystemPromptInputs {
  const SystemPromptInputs({
    required this.now,
    required this.tzName,
    this.profile,
    this.memories = const [],
    this.restrictions = const [],
    this.healthConsent = false,
    this.journalConsent = false,
  });

  final DateTime now;
  final String tzName;
  final UserProfile? profile;
  final List<AiMemory> memories;
  final List<HealthRestriction> restrictions;
  final bool healthConsent;
  final bool journalConsent;
}

const maxPromptMemories = 20;

String _styleLine(String style) => switch (style) {
  'encouraging' =>
    'Be warm and encouraging; celebrate progress, then give the next step.',
  'analytical' =>
    'Be analytical: lead with numbers, trends and the reasoning behind advice.',
  _ => 'Be direct and concise: answer first, then the one or two next steps.',
};

List<String> _jsonList(String json) {
  try {
    return (jsonDecode(json) as List).map((e) => e.toString()).toList();
  } catch (_) {
    return const [];
  }
}

String buildSystemPrompt(SystemPromptInputs i) {
  final p = i.profile;
  final style = p?.coachingStyle ?? 'direct';
  final b = StringBuffer()
    ..writeln(
      'You are Athlete OS Coach, a friendly personal fitness, nutrition and '
      'well-being coach inside the user\'s app. ${_styleLine(style)}',
    )
    ..writeln()
    ..writeln('Rules:')
    ..writeln(
      '- Use tools for every fact about the user (food, water, steps, '
      'training, habits, calendar, goals). Never invent or guess data.',
    )
    ..writeln(
      '- Cite dates and sources from tool provenance (e.g. "Health Connect, '
      'synced 9:40"). If data is missing or stale, say so plainly.',
    )
    ..writeln(
      '- Label clearly what is a measured fact, an estimate (e.g. AI-estimated '
      'food), and your recommendation.',
    )
    ..writeln(
      '- Ask before any change. Write tools show the user a confirmation '
      'card; never claim something was logged unless the tool result says so.',
    )
    ..writeln(
      '- Never change targets, goals or past records silently; suggest the '
      'change and let the user make it in the app.',
    )
    ..writeln(
      '- No medical diagnoses. Do not recommend extreme calorie cuts, '
      'dehydration, diuretics, laxatives or unsafe weight-cutting; suggest a '
      'qualified professional when appropriate.',
    )
    ..writeln(
      '- Respect recorded injuries/restrictions and the diet type; never '
      'suggest foods the user avoids.',
    )
    ..writeln(
      '- If the user seems in severe distress or mentions self-harm, respond '
      'with empathy, encourage contacting local emergency services or a '
      'crisis line and someone they trust, and do not continue coaching.',
    )
    ..writeln(
      '- Correlation is not causation: present patterns as possibilities.',
    )
    ..writeln(
      '- Strava data is unavailable to you by Strava policy; point the user '
      'to the on-device analysis in the Running screen.',
    )
    ..writeln(
      '- If a tool returns consent_required, explain how to allow it; do not '
      'retry the same tool in this turn.',
    )
    ..writeln(
      '- Keep answers short and scannable: short paragraphs, **bold** key '
      'numbers, "- " bullets. No tables.',
    )
    ..writeln()
    ..writeln('Context:')
    ..writeln(
      '- Now: ${DateFormat('EEEE, yyyy-MM-dd HH:mm').format(i.now)} '
      '(${i.tzName}). Today is ${LocalDates.key(i.now)}.',
    );
  if (p?.displayName != null && p!.displayName!.trim().isNotEmpty) {
    b.writeln('- User\'s name: ${p.displayName!.trim()}.');
  }
  if (i.healthConsent && p != null) {
    final restrictions = _jsonList(p.restrictionsJson);
    final disliked = _jsonList(p.dislikedFoodsJson);
    b
      ..writeln(
        '- Targets: ${p.calorieTarget} kcal, protein ${p.proteinTargetG.round()} g, '
        'carbs ${p.carbsTargetG.round()} g, fat ${p.fatTargetG.round()} g, '
        '${p.stepGoal} steps, ${p.waterGoalMl} ml water.',
      )
      ..writeln(
        '- Diet: ${p.dietType}'
        '${restrictions.isEmpty ? '' : '; avoids ${restrictions.join(', ')}'}'
        '${disliked.isEmpty ? '' : '; dislikes ${disliked.join(', ')}'}.',
      );
    if (p.fitnessGoals != null && p.fitnessGoals!.trim().isNotEmpty) {
      b.writeln('- Goals: ${p.fitnessGoals!.trim()}');
    }
    if (i.restrictions.isNotEmpty) {
      b.writeln('- Active injuries/restrictions (must respect):');
      for (final r in i.restrictions.take(10)) {
        b.writeln(
          '  - ${r.description}'
          '${r.bodyPart != null ? ' (${r.bodyPart})' : ''}'
          '${r.restriction != null ? ': ${r.restriction}' : ''}'
          '${r.clinicianImposed ? ' [clinician-imposed]' : ''}',
        );
      }
    }
  } else if (!i.healthConsent) {
    b.writeln(
      '- The user has not yet allowed health data to be shared with AI; '
      'health tools will ask for consent.',
    );
  }
  if (!i.journalConsent) {
    b.writeln('- Journal sharing is off; do not ask for journal content.');
  }
  final approved = i.memories.where((m) => m.approved).take(maxPromptMemories);
  if (approved.isNotEmpty) {
    b.writeln('- Things the user asked you to remember:');
    for (final m in approved) {
      b.writeln('  - (${m.category}) ${m.content}');
    }
  }
  return b.toString().trim();
}

/// Loads the minimal inputs for [buildSystemPrompt] from the local DB.
Future<SystemPromptInputs> loadSystemPromptInputs(
  AppDatabase db,
  SettingsRepository settings,
  DateTime now,
) async {
  final health =
      (await settings.get<bool>(SettingKeys.aiHealthConsent)) ?? false;
  final journal =
      (await settings.get<bool>(SettingKeys.aiJournalConsent)) ?? false;
  final memories =
      await (db.select(db.aiMemories)
            ..where((m) => m.approved.equals(true))
            ..orderBy([(m) => OrderingTerm.desc(m.updatedAt)])
            ..limit(maxPromptMemories))
          .get();
  return SystemPromptInputs(
    now: now,
    tzName: now.timeZoneName,
    profile: await loadProfile(db),
    memories: memories,
    restrictions: health
        ? await activeRestrictions(db, LocalDates.key(now))
        : const [],
    healthConsent: health,
    journalConsent: journal,
  );
}
