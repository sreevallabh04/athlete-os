import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/coach/agent/system_prompt.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'coach_test_utils.dart';

void main() {
  test('system prompt has rules + minimal context, no bulk history', () async {
    final db = newTestDb();
    addTearDown(db.close);
    await addFood(
      db,
      id: 'f1',
      date: testToday,
      kcal: 640,
      name: 'ZZ_BUTTER_CHICKEN',
    );
    await db
        .into(db.journalEntries)
        .insert(
          JournalEntriesCompanion.insert(
            id: 'j1',
            localDate: testToday,
            body: const Value('ZZ_PRIVATE_JOURNAL'),
          ),
        );
    await db
        .into(db.aiMemories)
        .insert(
          AiMemoriesCompanion.insert(
            id: 'm1',
            category: 'routine',
            content: 'Trains fasted at 6 am',
            approved: const Value(true),
          ),
        );
    await db
        .into(db.aiMemories)
        .insert(
          AiMemoriesCompanion.insert(
            id: 'm2',
            category: 'preference',
            content: 'ZZ_UNAPPROVED_MEMORY',
            origin: const Value('ai_suggested'),
          ),
        );
    await db
        .into(db.healthRestrictions)
        .insert(
          HealthRestrictionsCompanion.insert(
            id: 'r1',
            description: 'Left shoulder impingement',
            restriction: const Value('no overhead pressing'),
          ),
        );

    // Without health consent: no targets/restrictions.
    var prompt = buildSystemPrompt(
      await loadSystemPromptInputs(db, SettingsRepository(db), testNow),
    );
    expect(prompt, contains('Today is 2026-10-25'));
    expect(prompt, contains('Trains fasted at 6 am'));
    expect(prompt, isNot(contains('ZZ_UNAPPROVED_MEMORY')));
    expect(prompt, isNot(contains('ZZ_BUTTER_CHICKEN')));
    expect(prompt, isNot(contains('ZZ_PRIVATE_JOURNAL')));
    expect(prompt, isNot(contains('shoulder')));
    expect(prompt, contains('not yet allowed health data'));
    expect(prompt, contains('Strava'));
    expect(prompt, contains('Never invent'));
    expect(prompt, contains('diuretics'));

    await grantHealthConsent(db);
    prompt = buildSystemPrompt(
      await loadSystemPromptInputs(db, SettingsRepository(db), testNow),
    );
    expect(prompt, contains('2000 kcal'));
    expect(prompt, contains('Left shoulder impingement'));
    expect(prompt, contains('no overhead pressing'));
    expect(prompt, isNot(contains('ZZ_BUTTER_CHICKEN')));
    expect(prompt.length, lessThan(12000));
  });

  test('at most 20 approved memories are included', () async {
    final memories = [
      for (var i = 0; i < 30; i++)
        AiMemory(
          id: '$i',
          category: 'context',
          content: 'memory-$i;',
          origin: 'user',
          approved: true,
          createdAt: testNow,
          updatedAt: testNow,
        ),
    ];
    final prompt = buildSystemPrompt(
      SystemPromptInputs(now: testNow, tzName: 'UTC', memories: memories),
    );
    expect(RegExp('memory-').allMatches(prompt).length, maxPromptMemories);
  });

  test('coaching style changes the tone line', () {
    final p = buildSystemPrompt(
      SystemPromptInputs(
        now: testNow,
        tzName: 'UTC',
        profile: UserProfile(
          id: 1,
          dietType: 'vegan',
          restrictionsJson: '[]',
          dislikedFoodsJson: '[]',
          calorieTarget: 2200,
          proteinTargetG: 140,
          carbsTargetG: 250,
          fatTargetG: 70,
          stepGoal: 9000,
          waterGoalMl: 2500,
          wakeMinutes: 360,
          sleepMinutes: 1320,
          coachingStyle: 'analytical',
          runGoalDistanceM: 5000,
          runGoalTimeS: 1800,
          createdAt: testNow,
          updatedAt: testNow,
        ),
        healthConsent: true,
      ),
    );
    expect(p, contains('analytical'));
    expect(p, contains('vegan'));
  });
}
