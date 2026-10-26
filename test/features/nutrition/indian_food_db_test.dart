import 'dart:io';

import 'package:athlete_os/features/nutrition/application/ai_food_log.dart';
import 'package:athlete_os/features/nutrition/data/indian_food_db.dart';
import 'package:athlete_os/features/nutrition/domain/food_log_review.dart';
import 'package:athlete_os/features/nutrition/domain/food_models.dart';
import 'package:athlete_os/features/nutrition/domain/indian_food_db.dart';
import 'package:athlete_os/features/nutrition/domain/nutrients.dart';
import 'package:flutter_test/flutter_test.dart';

final csv = File(indianFoodCsvAsset).readAsStringSync();

ReviewItem item(String name, double grams, double kcal) => ReviewItem(
  id: name,
  name: name,
  grams: grams,
  nutrients: Nutrients(
    calories: kcal,
    protein: kcal * 0.05,
    carbs: kcal * 0.12,
    fat: kcal * 0.03,
  ),
  mealType: MealType.lunch,
  confidence: 0.7,
);

void main() {
  late IndianFoodIndex index;
  setUpAll(() => index = buildIndianFoodIndex(csv));

  group('CSV', () {
    test('bundled file parses to 1,014 dishes', () {
      final dishes = parseIndianFoodCsv(csv);
      expect(dishes, hasLength(1014));
      expect(dishes.first.name, 'Hot tea (Garam Chai)');
      expect(dishes.first.kcal, 16.14);
      expect(dishes.first.folateUg, 1.8); // the µg column
      expect(index.length, 1014);
    });

    test('quoted names keep their commas', () {
      final lemon = parseIndianFoodCsv(csv)
          .firstWhere((d) => d.name.startsWith('Lemon rice'));
      expect(lemon.name, 'Lemon rice (Pulihora, Elumichai sadam, Chitranna)');
      expect(lemon.kcal, 176.3);
      expect(lemon.protein, 4.26);
      expect(dishAliases(lemon.name), [
        'Lemon rice',
        'Pulihora',
        'Elumichai sadam',
        'Chitranna',
      ]);
    });

    test('RFC 4180 quoting, escaped quotes, CRLF, BOM', () {
      final rows = parseCsv('﻿a,b\r\n"x, ""y""",2\r\n"multi\nline",3\r\n\r\n');
      expect(rows, [
        ['a', 'b'],
        ['x, "y"', '2'],
        ['multi\nline', '3'],
      ]);
    });

    test('empty micronutrient cells are null; bad rows are skipped', () {
      final last = parseIndianFoodCsv(csv).last;
      expect(last.name, 'Bengal 5 Spice Blend (Panch Phoran)');
      expect(last.ironMg, 13.37);
      expect(last.vitaminCMg, isNull);
      expect(last.folateUg, isNull);
      final small = parseIndianFoodCsv(
        'Dish Name,Calories (kcal),Carbohydrates (g),Protein (g),Fats (g)\n'
        'Good,100,10,5,2\n'
        ',100,10,5,2\n'
        'No energy,,10,5,2\n',
      );
      expect(small.map((d) => d.name), ['Good']);
      expect(small.single.fiber, isNull);
    });
  });

  group('normalisation & aliases', () {
    test('case, diacritics and punctuation', () {
      expect(
        normalizeFoodText('  Crème BRÛLÉE (Sweet)!! '),
        'creme brulee sweet',
      );
      expect(normalizeFoodText('Dal-makhani/Kali dal'), 'dal makhani kali dal');
    });

    test('slash variants stay specific', () {
      expect(expandSlashVariants('Chapati/Roti'), ['Chapati', 'Roti']);
      expect(expandSlashVariants('Dal parantha/paratha'), [
        'Dal parantha',
        'Dal paratha',
      ]);
      expect(expandSlashVariants('Suji/Rava upma'), ['Suji upma', 'Rava upma']);
      expect(dishAliases('Hot tea (Garam Chai)'), ['Hot tea', 'Garam Chai']);
      expect(
        dishAliases('Paneer pea sandwich (toasted) (Paneer matar ka sandwich)'),
        ['Paneer pea sandwich toasted', 'Paneer matar ka sandwich'],
      );
    });
  });

  group('search', () {
    test('"chai" finds Hot tea (Garam Chai) first', () {
      final hits = index.search('chai');
      expect(hits.first.dish.name, 'Hot tea (Garam Chai)');
    });

    test('exact > prefix > words > contains', () {
      expect(index.search('Idli').first.dish.name, 'Idli');
      expect(index.search('IDLI').first.score, 100);
      final roti = index.search('roti');
      expect(roti.first.dish.name, 'Chapati/Roti'); // exact alias
      expect(roti.length, greaterThan(3)); // makki ki roti, soya roti...
      expect(index.search('kadhai pan').first.dish.name, 'Kadhai Paneer');
      expect(index.search('x'), isEmpty);
    });

    test('"paneer bhurji": no such dish, closest paneer/bhurji dishes', () {
      final hits = index.search('paneer bhurji');
      expect(hits, isNotEmpty);
      expect(hits.first.score, lessThan(60)); // only partial matches
      expect(
        hits.take(5).every((h) {
          final n = normalizeFoodText(h.dish.name);
          return n.contains('paneer') || n.contains('bhurji');
        }),
        isTrue,
      );
    });
  });

  group('AI item matcher (conservative)', () {
    String? m(String name) => index.match(name)?.dish.name;

    test('exact names and aliases match', () {
      expect(m('Roti'), 'Chapati/Roti');
      expect(m('Rotis'), 'Chapati/Roti');
      expect(m('Chapati'), 'Chapati/Roti');
      expect(m('Idli'), 'Idli');
      expect(m('Boiled rice'), 'Boiled rice (Uble chawal)');
      expect(m('Palak paneer'), 'Spinach paneer (Palak paneer)');
      expect(m('Matar paneer'), 'Pea paneer curry (Matar paneer)');
      expect(m('Rava upma'), 'Semolina upma (Suji/Rava upma)');
      expect(m('Omelette'), 'Plain omelette/omlet');
    });

    test('high token overlap matches; the 0.67 threshold is respected', () {
      // Stop words ("ka") are ignored: exact alias match.
      expect(
        m('Moong dal cheela'),
        'Moong dal stuffed cheela/chilla (Moong dal ka cheela/chilla)',
      );
      // 3 of 4 words (0.75) → match.
      expect(
        m('Rice moong cheela'),
        'Rice moong dal cheela (Chawal aur moong dal ka cheela)',
      );
      // 2 of 3 words (0.67 rounded down) → no match.
      expect(m('Moong poha'), isNull);
    });

    test('different dishes never match', () {
      expect(m('Whey protein'), isNull); // not "Whey soup"
      expect(m('Paneer bhurji'), isNull); // not "Ande ki bhurji"
      expect(m('Egg omelette'), isNull); // ambiguous among omelettes
      expect(m('Paneer butter masala'), isNull);
      expect(m('Masala chai'), isNull);
      expect(m('Dal'), isNull);
      expect(m('Rice'), isNull);
    });
  });

  group('AI food log grounding', () {
    test('matched item: per 100 g × AI grams, DB source; toggle back', () {
      final ai = item('Roti', 80, 240);
      final grounded = groundWithIndianDb([ai], index).single;
      expect(grounded.usesDb, isTrue);
      expect(grounded.grounding!.dish.name, 'Chapati/Roti');
      expect(grounded.nutrients.calories, closeTo(161.8, 0.05)); // 202.31×0.8
      expect(grounded.nutrients.protein, closeTo(4.7, 0.05));
      expect(grounded.nutrients.fiber, closeTo(5.0, 0.05));

      final draft = logDraftsFor([grounded]).single;
      expect(draft.source, FoodSources.indianFoodDb);
      expect(draft.verification, Verifications.database);
      expect(draft.note, contains('Indian Food DB: Chapati/Roti'));

      final back = grounded.withDbValues(false);
      expect(back.usesDb, isFalse);
      expect(back.nutrients.calories, 240);
      expect(logDraftsFor([back]).single.source, FoodSources.aiEstimate);
      expect(back.withDbValues(true).nutrients.calories, closeTo(161.8, 0.05));

      // Changing grams keeps DB values exact and scales the AI estimate.
      final doubled = grounded.scaledToGrams(160);
      expect(doubled.nutrients.calories, closeTo(323.7, 0.05));
      expect(doubled.grounding!.aiNutrients.calories, 480);
    });

    test('no match / no grams → AI estimate unchanged', () {
      final whey = item('Whey protein', 30, 120);
      const noGrams = ReviewItem(
        id: 'x',
        name: 'Idli',
        nutrients: Nutrients(calories: 80),
        mealType: MealType.breakfast,
      );
      final out = groundWithIndianDb([whey, noGrams], index);
      expect(out[0].usesDb, isFalse);
      expect(out[0].grounding, isNull);
      expect(out[0].nutrients.calories, 120);
      expect(out[1].grounding, isNull);
      expect(logDraftsFor(out).every((d) => d.source == 'ai_estimate'), isTrue);
    });

    test('sample day paste: match rate', () {
      // A typical day as the AI parser names items.
      const day = [
        'Masala chai',
        'Poha',
        'Banana',
        'Egg omelette',
        'Roti',
        'Dal tadka',
        'Boiled rice',
        'Paneer bhurji',
        'Curd',
        'Whey protein',
        'Idli',
        'Sambar',
        'Coconut chutney',
        'Palak paneer',
        'Chapati',
      ];
      final items = [for (final n in day) item(n, 100, 200)];
      final grounded = groundWithIndianDb(items, index);
      final matched = {
        for (final g in grounded)
          if (g.usesDb) g.name: g.grounding!.dish.name,
      };
      // ignore: avoid_print
      print('Indian Food DB matches ${matched.length}/${day.length}: $matched');
      expect(matched.keys, containsAll(['Roti', 'Chapati', 'Idli', 'Poha']));
      expect(matched.keys, isNot(contains('Whey protein')));
      expect(matched.keys, isNot(contains('Paneer bhurji')));
    });
  });

  test('IndianFoodDb loads once and shares the index', () async {
    var loads = 0;
    final db = IndianFoodDb(
      loadCsv: () async {
        loads++;
        return csv;
      },
      build: (c) async => buildIndianFoodIndex(c),
    );
    expect(db.readyIndex, isNull);
    final a = await db.index();
    final b = await db.index();
    expect(identical(a, b), isTrue);
    expect(loads, 1);
    expect(db.readyIndex, same(a));
  });
}
