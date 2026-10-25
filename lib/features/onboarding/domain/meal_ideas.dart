/// Eggetarian, Indian-friendly meal ideas with macros computed from a small
/// embedded nutrient table. Pure Dart, deterministic.
///
/// Nutrient values are per 100 g and are generic ESTIMATES based on USDA
/// FoodData Central (SR Legacy / Foundation) and IFCT 2017 style values for
/// Indian staples; brands and recipes vary, so label as estimates.
library;

class NutrientRow {
  const NutrientRow(this.kcal, this.protein, this.carbs, this.fat);
  final double kcal;
  final double protein;
  final double carbs;
  final double fat;
}

/// Per 100 g. Source hints in comments.
const nutrientTable = <String, NutrientRow>{
  'paneer': NutrientRow(265, 18.3, 3.6, 20.8), // IFCT-style full-fat paneer
  'egg_whole': NutrientRow(143, 12.6, 0.7, 9.5), // USDA 171287
  'egg_white': NutrientRow(52, 10.9, 0.7, 0.2), // USDA 172183
  'curd': NutrientRow(61, 3.5, 4.7, 3.3), // USDA plain whole-milk yogurt
  'greek_yogurt': NutrientRow(59, 10.2, 3.6, 0.4), // USDA nonfat Greek
  'whey': NutrientRow(400, 78, 8, 6), // generic whey concentrate label
  'soya_chunks': NutrientRow(345, 52, 33, 0.5), // dry, generic label
  'moong_dal': NutrientRow(348, 24, 60, 1.2), // dry split moong
  'rice_cooked': NutrientRow(130, 2.7, 28.2, 0.3), // USDA white rice cooked
  'roti': NutrientRow(270, 9, 52, 2.5), // whole-wheat phulka, no ghee
  'banana': NutrientRow(89, 1.1, 22.8, 0.3), // USDA 173944
  'oats': NutrientRow(379, 13.2, 67.7, 6.5), // USDA rolled oats
  'besan': NutrientRow(387, 22.4, 57.8, 6.7), // USDA chickpea flour
  'tofu': NutrientRow(144, 17.3, 2.8, 8.7), // USDA firm tofu
  'milk_toned': NutrientRow(60, 3.2, 4.8, 3.0), // Indian toned milk (3 %)
  'vegetables': NutrientRow(40, 2, 7, 0.3), // mixed non-starchy veg
  'oil': NutrientRow(884, 0, 0, 100), // any cooking oil / ghee ≈ 900
  'peanut_butter': NutrientRow(588, 25, 20, 50), // USDA smooth
  'ww_bread': NutrientRow(247, 13, 41, 3.4), // USDA whole-wheat bread
  'chickpeas': NutrientRow(164, 8.9, 27.4, 2.6), // USDA boiled
  'poha': NutrientRow(346, 6.6, 77, 1.2), // dry flattened rice
};

const ingredientLabels = <String, String>{
  'paneer': 'Paneer',
  'egg_whole': 'Whole egg',
  'egg_white': 'Egg white',
  'curd': 'Curd (dahi)',
  'greek_yogurt': 'Hung curd / Greek yogurt',
  'whey': 'Whey protein',
  'soya_chunks': 'Soya chunks (dry)',
  'moong_dal': 'Moong dal (dry)',
  'rice_cooked': 'Rice (cooked)',
  'roti': 'Roti',
  'banana': 'Banana',
  'oats': 'Oats',
  'besan': 'Besan',
  'tofu': 'Tofu',
  'milk_toned': 'Toned milk',
  'vegetables': 'Vegetables',
  'oil': 'Oil / ghee',
  'peanut_butter': 'Peanut butter',
  'ww_bread': 'Whole-wheat bread',
  'chickpeas': 'Chickpeas (boiled)',
  'poha': 'Poha (dry)',
};

class Ingredient {
  const Ingredient(this.key, this.grams);
  final String key;
  final double grams;
}

class MealIdea {
  const MealIdea({
    required this.name,
    required this.ingredients,
    required this.slot,
    this.note,
  });

  final String name;
  final List<Ingredient> ingredients;

  /// breakfast | lunch | snack | dinner | any
  final String slot;
  final String? note;

  NutrientRow get macros {
    var k = 0.0, p = 0.0, c = 0.0, f = 0.0;
    for (final i in ingredients) {
      final n = nutrientTable[i.key]!;
      final m = i.grams / 100;
      k += n.kcal * m;
      p += n.protein * m;
      c += n.carbs * m;
      f += n.fat * m;
    }
    return NutrientRow(k, p, c, f);
  }

  int get kcal => macros.kcal.round();
  int get proteinG => macros.protein.round();
  int get carbsG => macros.carbs.round();
  int get fatG => macros.fat.round();
  bool get containsEgg =>
      ingredients.any((i) => i.key == 'egg_whole' || i.key == 'egg_white');
  bool get containsDairy => ingredients.any(
    (i) => const {
      'paneer',
      'curd',
      'greek_yogurt',
      'whey',
      'milk_toned',
    }.contains(i.key),
  );

  String get ingredientSummary => [
    for (final i in ingredients)
      '${ingredientLabels[i.key] ?? i.key} ${i.grams.round()} g',
  ].join(' · ');
}

const mealLibrary = <MealIdea>[
  MealIdea(
    name: 'Paneer bhurji + 2 rotis',
    slot: 'dinner',
    ingredients: [
      Ingredient('paneer', 100),
      Ingredient('vegetables', 80),
      Ingredient('oil', 5),
      Ingredient('roti', 80),
    ],
  ),
  MealIdea(
    name: 'Egg-white omelette + toast',
    slot: 'breakfast',
    ingredients: [
      Ingredient('egg_white', 200),
      Ingredient('egg_whole', 50),
      Ingredient('vegetables', 60),
      Ingredient('oil', 3),
      Ingredient('ww_bread', 60),
    ],
  ),
  MealIdea(
    name: 'Hung-curd protein bowl',
    slot: 'snack',
    ingredients: [
      Ingredient('greek_yogurt', 250),
      Ingredient('oats', 30),
      Ingredient('banana', 80),
    ],
  ),
  MealIdea(
    name: 'Soya chunks curry + rice',
    slot: 'lunch',
    ingredients: [
      Ingredient('soya_chunks', 50),
      Ingredient('vegetables', 100),
      Ingredient('oil', 7),
      Ingredient('rice_cooked', 150),
    ],
  ),
  MealIdea(
    name: 'Moong dal + rice + curd',
    slot: 'lunch',
    ingredients: [
      Ingredient('moong_dal', 50),
      Ingredient('rice_cooked', 150),
      Ingredient('curd', 150),
      Ingredient('oil', 5),
    ],
  ),
  MealIdea(
    name: 'Whey + banana shake',
    slot: 'snack',
    ingredients: [
      Ingredient('whey', 30),
      Ingredient('banana', 120),
      Ingredient('milk_toned', 200),
    ],
  ),
  MealIdea(
    name: 'Besan-egg chilla + curd',
    slot: 'breakfast',
    ingredients: [
      Ingredient('besan', 50),
      Ingredient('egg_white', 100),
      Ingredient('vegetables', 50),
      Ingredient('oil', 5),
      Ingredient('curd', 150),
    ],
  ),
  MealIdea(
    name: 'Tofu stir-fry + rice',
    slot: 'dinner',
    ingredients: [
      Ingredient('tofu', 150),
      Ingredient('vegetables', 150),
      Ingredient('oil', 7),
      Ingredient('rice_cooked', 120),
    ],
  ),
  MealIdea(
    name: 'Egg bhurji + 2 rotis',
    slot: 'dinner',
    ingredients: [
      Ingredient('egg_whole', 100),
      Ingredient('egg_white', 100),
      Ingredient('vegetables', 50),
      Ingredient('oil', 5),
      Ingredient('roti', 80),
    ],
  ),
  MealIdea(
    name: 'Overnight protein oats',
    slot: 'breakfast',
    ingredients: [
      Ingredient('oats', 50),
      Ingredient('whey', 30),
      Ingredient('milk_toned', 200),
    ],
  ),
  MealIdea(
    name: 'Boiled eggs snack (1 whole + 4 whites)',
    slot: 'snack',
    ingredients: [Ingredient('egg_whole', 50), Ingredient('egg_white', 130)],
  ),
  MealIdea(
    name: 'Chana-paneer salad',
    slot: 'lunch',
    ingredients: [
      Ingredient('chickpeas', 120),
      Ingredient('paneer', 60),
      Ingredient('vegetables', 120),
    ],
  ),
  MealIdea(
    name: 'Curd + whey bedtime bowl',
    slot: 'snack',
    ingredients: [Ingredient('curd', 200), Ingredient('whey', 20)],
    note: 'Slow-digesting protein before bed.',
  ),
  MealIdea(
    name: 'Poha with soya & peanuts',
    slot: 'breakfast',
    ingredients: [
      Ingredient('poha', 50),
      Ingredient('soya_chunks', 25),
      Ingredient('vegetables', 60),
      Ingredient('oil', 5),
    ],
  ),
];

/// Meals compatible with [dietType] and not containing any [dislikes]
/// (matched case-insensitively against ingredient keys/labels and names).
List<MealIdea> mealsForDiet(
  String dietType, {
  List<String> dislikes = const [],
  List<MealIdea> library = mealLibrary,
}) {
  final bad = [
    for (final d in dislikes)
      if (d.trim().isNotEmpty) d.trim().toLowerCase(),
  ];
  bool disliked(MealIdea m) {
    final text = [
      m.name,
      for (final i in m.ingredients) ...[i.key, ingredientLabels[i.key] ?? ''],
    ].join(' ').toLowerCase();
    return bad.any(text.contains);
  }

  return [
    for (final m in library)
      if (!(dietType == 'vegetarian' && m.containsEgg) &&
          !(dietType == 'vegan' && (m.containsEgg || m.containsDairy)) &&
          !disliked(m))
        m,
  ];
}

/// Deterministic suggestions for what's left today.
///
/// * Only meals that fit [kcalLeft] (+5 % tolerance) are eligible.
/// * While protein is still needed, rank by protein still-needed-covered per
///   kcal (`min(P, proteinLeft) / kcal`), so lean, protein-dense meals win.
/// * Once protein is covered, rank by how fully the meal uses the remaining
///   energy (largest kcal first).
/// * Ties break alphabetically.
List<MealIdea> mealIdeasForRemaining(
  double kcalLeft,
  double proteinLeft, {
  List<MealIdea> library = mealLibrary,
  int limit = 5,
}) {
  if (kcalLeft < 100) return const [];
  final fits = [
    for (final m in library)
      if (m.macros.kcal <= kcalLeft * 1.05) m,
  ];
  double score(MealIdea m) {
    final mac = m.macros;
    if (proteinLeft > 0) {
      final covered = mac.protein < proteinLeft ? mac.protein : proteinLeft;
      return covered / mac.kcal;
    }
    return mac.kcal;
  }

  fits.sort((a, b) {
    final c = score(b).compareTo(score(a));
    return c != 0 ? c : a.name.compareTo(b.name);
  });
  return fits.take(limit).toList();
}
