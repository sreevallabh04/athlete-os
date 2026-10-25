import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/data/repositories/profile_repository.dart';
import 'package:athlete_os/features/planning/data/profile_mapping.dart';
import 'package:athlete_os/features/planning/domain/profile_diff.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  const base = ProfileDraft(displayName: 'Sai', restrictions: ['peanuts']);

  test('identical drafts have no changes; blank text equals null', () {
    expect(diffProfile(base, base), isEmpty);
    expect(
      diffProfile(
        const ProfileDraft(),
        const ProfileDraft(displayName: '  ', fitnessGoals: ''),
      ),
      isEmpty,
    );
    // 150 vs 150.0 is not a change.
    expect(
      diffProfile(
        const ProfileDraft(proteinTargetG: 150),
        const ProfileDraft(proteinTargetG: 150.0),
      ),
      isEmpty,
    );
  });

  test('detects target and non-target changes with old -> new text', () {
    const after = ProfileDraft(
      displayName: 'Sai K',
      restrictions: ['peanuts', 'lactose'],
      calorieTarget: 2200,
      proteinTargetG: 165,
      runGoalTimeS: 1740,
    );
    final changes = diffProfile(base, after);
    final byKey = {for (final c in changes) c.key: c};
    expect(byKey.keys.toSet(), {
      'displayName',
      'restrictions',
      'calorieTarget',
      'proteinTargetG',
      'runGoalTimeS',
    });
    expect(byKey['calorieTarget']!.isTarget, isTrue);
    expect(
      byKey['calorieTarget']!.toString(),
      'Calorie target (kcal): 2000 → 2200',
    );
    expect(byKey['proteinTargetG']!.oldText, '150');
    expect(byKey['runGoalTimeS']!.newText, '29:00');
    expect(byKey['displayName']!.isTarget, isFalse);
    expect(byKey['restrictions']!.newText, 'peanuts, lactose');
  });

  test('optional target cleared shows a dash', () {
    final c = diffProfile(
      const ProfileDraft(fiberTargetG: 30),
      const ProfileDraft(),
    ).single;
    expect(c.key, 'fiberTargetG');
    expect(c.newText, '—');
  });

  test('calorie caution: floor and large drop, never blocks', () {
    expect(calorieCaution(2000, 1450), CalorieCaution.belowFloor);
    expect(calorieCaution(2400, 1700), CalorieCaution.largeDrop); // -29%
    expect(calorieCaution(2400, 1800), CalorieCaution.none); // -25% exactly
    expect(calorieCaution(2000, 2500), CalorieCaution.none);
    expect(
      calorieCautionMessage(CalorieCaution.belowFloor),
      contains('dietitian'),
    );
  });

  test('duration helpers', () {
    expect(parseDuration('30:00'), 1800);
    expect(parseDuration('1:02:05'), 3725);
    expect(parseDuration('1800'), 1800);
    expect(parseDuration('abc'), isNull);
    expect(parseDuration('1:2:3:4'), isNull);
    expect(formatSeconds(1800), '30:00');
    expect(formatSeconds(3725), '1:02:05');
    expect(formatMinutes(390), '06:30');
  });

  test('saving through ProfileRepository logs only changed fields', () async {
    final db = newTestDb();
    addTearDown(db.close);
    final repo = ProfileRepository(db);
    final before = draftFromProfile(await repo.get());
    const after = ProfileDraft(calorieTarget: 2300, displayName: 'Sai');
    expect(diffProfile(before, after).map((c) => c.key).toSet(), {
      'calorieTarget',
      'displayName',
    });
    await repo.update(companionFromDraft(after));
    final history = await repo.history();
    expect(history.map((h) => h.metric).toSet(), {
      'calorieTarget',
      'displayName',
    });
    final cal = history.firstWhere((h) => h.metric == 'calorieTarget');
    expect(cal.oldValue, '2000');
    expect(cal.newValue, '2300');
    final saved = await repo.get();
    expect(saved, isA<UserProfile>());
    expect(draftFromProfile(saved).calorieTarget, 2300);
  });
}
