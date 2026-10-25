import 'package:athlete_os/features/nutrition/domain/nl_parser.dart';
import 'package:athlete_os/features/nutrition/domain/nutrients.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseFoodText', () {
    test('the canonical example', () {
      final items = parseFoodText('150 g paneer, 200 g rice and one banana');
      expect(items, hasLength(3));
      expect(items[0].quantity, 150);
      expect(items[0].unit, ParsedUnit.gram);
      expect(items[0].name, 'paneer');
      expect(items[1].quantity, 200);
      expect(items[1].name, 'rice');
      expect(items[2].quantity, 1);
      expect(items[2].unit, ParsedUnit.piece);
      expect(items[2].name, 'banana');
    });

    test('glued units and kg/l conversion', () {
      final items = parseFoodText('150g curd; 0.5kg watermelon + 1.5l water');
      expect(items.map((i) => i.quantity).toList(), [150, 500, 1500]);
      expect(items[0].unit, ParsedUnit.gram);
      expect(items[1].unit, ParsedUnit.gram);
      expect(items[2].unit, ParsedUnit.millilitre);
      expect(items[2].name, 'water');
    });

    test('word numbers, fractions, "of", cups, servings', () {
      final items = parseFoodText(
        'two rotis\nhalf a cup of dal\n1/2 serving poha\n1 1/2 cups milk\n'
        '3 pieces of chikki\n½ apple',
      );
      expect(items[0].quantity, 2);
      expect(items[0].name, 'rotis');
      expect(items[1].quantity, 0.5);
      expect(items[1].unit, ParsedUnit.cup);
      expect(items[1].name, 'dal');
      expect(items[2].quantity, 0.5);
      expect(items[2].unit, ParsedUnit.serving);
      expect(items[3].quantity, 1.5);
      expect(items[3].unit, ParsedUnit.cup);
      expect(items[4].quantity, 3);
      expect(items[4].unit, ParsedUnit.piece);
      expect(items[4].name, 'chikki');
      expect(items[5].quantity, 0.5);
      expect(items[5].name, 'apple');
    });

    test('no quantity defaults to one serving, flagged as implicit', () {
      final items = parseFoodText('masala dosa');
      expect(items.single.quantity, 1);
      expect(items.single.unit, ParsedUnit.serving);
      expect(items.single.explicitQuantity, isFalse);
      expect(items.single.name, 'masala dosa');
    });

    test('ignores empty segments and trailing punctuation', () {
      final items = parseFoodText(' , and 2 eggs. ,, ');
      expect(items, hasLength(1));
      expect(items.single.name, 'eggs');
    });

    test('a lone number without food is dropped', () {
      expect(parseFoodText('200 g'), isEmpty);
    });

    test('comma decimals are not split mid-number when glued', () {
      final items = parseFoodText('2.5 servings oats');
      expect(items.single.quantity, 2.5);
      expect(items.single.unit, ParsedUnit.serving);
    });
  });

  group('matchScore', () {
    test('exact, contains, plural', () {
      expect(matchScore('paneer', 'Paneer'), 100);
      expect(matchScore('bananas', 'Banana'), 100);
      expect(matchScore('rice', 'Basmati rice, cooked'), greaterThan(60));
      expect(matchScore('brown rice cooked', 'rice'), 60);
      expect(matchScore('paneer', 'Rice'), 0);
    });
  });

  group('matchParsedFoods', () {
    const paneer = FoodRef(
      id: 'p',
      name: 'Paneer',
      basis: ServingBasis(
        perServing: Nutrients(
          calories: 265,
          protein: 18.3,
          carbs: 1.2,
          fat: 20.8,
        ),
        servingSize: 100,
        servingUnit: 'g',
        gramsPerServing: 100,
      ),
    );
    const rice = FoodRef(
      id: 'r',
      name: 'Rice, cooked',
      basis: ServingBasis(
        perServing: Nutrients(calories: 130, protein: 2.7, carbs: 28, fat: 0.3),
        servingSize: 100,
        servingUnit: 'g',
        gramsPerServing: 100,
      ),
    );
    const banana = FoodRef(
      id: 'b',
      name: 'Banana',
      basis: ServingBasis(
        perServing: Nutrients(calories: 105, protein: 1.3, carbs: 27, fat: 0.4),
        servingSize: 1,
        servingUnit: 'piece',
        gramsPerServing: 118,
      ),
    );
    const milk = FoodRef(
      id: 'm',
      name: 'Milk',
      basis: ServingBasis(
        perServing: Nutrients(calories: 62, protein: 3.2, carbs: 4.8, fat: 3.3),
        servingSize: 100,
        servingUnit: 'ml',
        gramsPerServing: 100,
      ),
    );
    final foods = [paneer, rice, banana, milk];

    test('matches the canonical example with deterministic totals', () {
      final m = matchParsedFoods(
        parseFoodText('150 g paneer, 200 g rice and one banana'),
        foods,
      );
      expect(m.map((x) => x.status), everyElement(MatchStatus.matched));
      expect(m[0].food!.id, 'p');
      expect(m[0].resolved!.nutrients.calories, closeTo(397.5, 1e-9));
      expect(m[1].food!.id, 'r');
      expect(m[1].resolved!.nutrients.calories, closeTo(260, 1e-9));
      expect(m[2].food!.id, 'b');
      expect(m[2].amount!.mode, AmountMode.servings);
      expect(m[2].resolved!.nutrients.calories, 105);
    });

    test('unmatched items need lookup', () {
      final m = matchParsedFoods(parseFoodText('2 idli'), foods);
      expect(m.single.status, MatchStatus.needsLookup);
      expect(m.single.food, isNull);
    });

    test('unconvertible units need an amount (no guessing)', () {
      final m = matchParsedFoods(
        parseFoodText('1 cup rice, one paneer, 100 ml banana'),
        foods,
      );
      expect(m.map((x) => x.status).toSet(), {MatchStatus.needsAmount});
    });

    test('ml for liquids and servings', () {
      final m = matchParsedFoods(
        parseFoodText('250 ml milk, 2 servings rice'),
        foods,
      );
      expect(m[0].resolved!.nutrients.calories, closeTo(155, 1e-9));
      expect(m[1].resolved!.grams, 200);
    });

    test('earlier foods win ties (recents first)', () {
      const paneer2 = FoodRef(
        id: 'p2',
        name: 'Paneer',
        basis: ServingBasis(perServing: Nutrients(calories: 300)),
      );
      final m = matchParsedFoods(parseFoodText('paneer'), [paneer2, paneer]);
      expect(m.single.food!.id, 'p2');
    });
  });
}
