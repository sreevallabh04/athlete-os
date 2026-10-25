import 'package:athlete_os/features/onboarding/domain/meal_ideas.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('library macros are computed from the nutrient table', () {
    final shake = mealLibrary.firstWhere((m) => m.name.startsWith('Whey'));
    // 30 g whey (120 kcal, 23.4 P) + 120 g banana (106.8) + 200 ml milk (120)
    expect(shake.kcal, 347);
    expect(shake.proteinG, 31);
    for (final m in mealLibrary) {
      expect(m.kcal, greaterThan(100), reason: m.name);
      final fromMacros =
          m.macros.protein * 4 + m.macros.carbs * 4 + m.macros.fat * 9;
      expect(
        (fromMacros - m.macros.kcal).abs() / m.macros.kcal,
        lessThan(0.15),
        reason: m.name,
      );
    }
  });

  test('every library meal is eggetarian-friendly', () {
    expect(mealsForDiet('eggetarian'), hasLength(mealLibrary.length));
    expect(mealsForDiet('vegetarian').any((m) => m.containsEgg), isFalse);
    expect(
      mealsForDiet(
        'eggetarian',
        dislikes: ['tofu'],
      ).any((m) => m.name.toLowerCase().contains('tofu')),
      isFalse,
    );
  });

  test('ranking prefers protein per kcal and is deterministic', () {
    final a = mealIdeasForRemaining(1200, 120);
    final b = mealIdeasForRemaining(1200, 120);
    expect(a.map((m) => m.name), b.map((m) => m.name));
    expect(a, hasLength(5));
    double density(MealIdea m) => m.macros.protein / m.macros.kcal;
    for (var i = 1; i < a.length; i++) {
      expect(density(a[i - 1]), greaterThanOrEqualTo(density(a[i])));
    }
    expect(a.first.name, contains('Boiled eggs'));
  });

  test('only meals that fit the remaining kcal are suggested', () {
    final small = mealIdeasForRemaining(260, 40);
    expect(small, isNotEmpty);
    for (final m in small) {
      expect(m.macros.kcal, lessThanOrEqualTo(260 * 1.05));
    }
    expect(mealIdeasForRemaining(50, 30), isEmpty);
  });

  test('when protein is covered, fill remaining energy', () {
    final r = mealIdeasForRemaining(500, 0);
    expect(r.first.macros.kcal, greaterThanOrEqualTo(r.last.macros.kcal));
  });
}
