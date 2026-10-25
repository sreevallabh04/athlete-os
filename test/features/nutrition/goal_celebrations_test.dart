import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/nutrition/presentation/widgets/common.dart';
import 'package:athlete_os/features/nutrition/presentation/widgets/nutrition_hud.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  test('a goal celebrates at most once per day', () async {
    final db = newTestDb();
    addTearDown(db.close);
    final settings = SettingsRepository(db);

    expect(
      await GoalCelebrations.claim(settings, 'protein', '2026-10-25'),
      isTrue,
    );
    expect(
      await GoalCelebrations.claim(settings, 'protein', '2026-10-25'),
      isFalse,
    );
    // Other goals and other days are independent.
    expect(
      await GoalCelebrations.claim(settings, 'water', '2026-10-25'),
      isTrue,
    );
    expect(
      await GoalCelebrations.claim(settings, 'protein', '2026-10-26'),
      isTrue,
    );
  });

  test('preciseMl keeps hydration precision', () {
    expect(preciseMl(750), '750 ml');
    expect(preciseMl(1750), '1.75 L');
    expect(preciseMl(2500), '2.5 L');
    expect(preciseMl(3000), '3 L');
  });
}
