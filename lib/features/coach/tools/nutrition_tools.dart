import 'package:drift/drift.dart';

import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import 'tool_args_validator.dart';
import 'tool_spec.dart';
import 'tool_support.dart';

Future<UserProfile?> loadProfile(AppDatabase db) => (db.select(
  db.userProfiles,
)..where((p) => p.id.equals(1))).getSingleOrNull();

/// Per-day nutrient totals. Soft-deleted entries are always excluded.
class DayNutrition {
  double calories = 0;
  double protein = 0;
  double carbs = 0;
  double fat = 0;
  double fiber = 0;
  int entries = 0;
  int estimatedEntries = 0;

  void add(FoodLogEntry e) {
    calories += e.calories;
    protein += e.proteinG;
    carbs += e.carbsG;
    fat += e.fatG;
    fiber += e.fiberG ?? 0;
    entries++;
    if (e.verification == 'estimate') estimatedEntries++;
  }

  Map<String, Object?> toJson() => {
    'calories_kcal': r1(calories),
    'protein_g': r1(protein),
    'carbs_g': r1(carbs),
    'fat_g': r1(fat),
    'fiber_g': r1(fiber),
    'entries': entries,
    'estimated_entries': estimatedEntries,
  };
}

Future<List<FoodLogEntry>> foodEntries(AppDatabase db, DateRange range) =>
    (db.select(db.foodLogEntries)
          ..where(
            (f) =>
                f.localDate.isBetweenValues(range.start, range.end) &
                f.deletedAt.isNull(),
          )
          ..orderBy([(f) => OrderingTerm.asc(f.loggedAt)]))
        .get();

Map<String, DayNutrition> totalsByDay(
  List<FoodLogEntry> entries,
  DateRange range,
) {
  final out = {for (final d in range.days) d: DayNutrition()};
  for (final e in entries) {
    out[e.localDate]?.add(e);
  }
  return out;
}

Map<String, Object?> targetsJson(UserProfile p) => {
  'calories_kcal': p.calorieTarget,
  'protein_g': r1(p.proteinTargetG),
  'carbs_g': r1(p.carbsTargetG),
  'fat_g': r1(p.fatTargetG),
  'fiber_g': ?p.fiberTargetG == null ? null : r1(p.fiberTargetG!),
};

/// remaining = target − consumed (negative means over target).
Map<String, Object?> remainingJson(UserProfile p, DayNutrition d) => {
  'calories_kcal': r1(p.calorieTarget - d.calories),
  'protein_g': r1(p.proteinTargetG - d.protein),
  'carbs_g': r1(p.carbsTargetG - d.carbs),
  'fat_g': r1(p.fatTargetG - d.fat),
  'fiber_g': ?p.fiberTargetG == null ? null : r1(p.fiberTargetG! - d.fiber),
};

final getNutritionSummaryTool = ToolSpec(
  name: 'get_nutrition_summary',
  description:
      'Logged food totals (kcal, protein, carbs, fat, fiber) for one day or a '
      'range (max 31 days), with targets and remaining amounts. Single-day '
      'requests also list entries. Values marked estimate are approximations.',
  inputSchema: S.object(dateRangeProps()),
  consent: ToolConsent.health,
  chipLabel: (a, now) => 'Read nutrition · ${chipRange(a, now)}',
  handler: (ctx, args) async {
    final range = resolveRange(args, ctx.today);
    final profile = await loadProfile(ctx.db);
    final entries = await foodEntries(ctx.db, range);
    final byDay = totalsByDay(entries, range);
    final sources = entries.map((e) => sourceLabel(e.source)).toSet();
    final missing = <String>[
      for (final d in range.days)
        if (byDay[d]!.entries == 0) 'no food logged on $d',
    ];
    final result = <String, Object?>{
      'targets': ?profile == null ? null : targetsJson(profile),
    };
    if (range.isSingleDay) {
      final d = byDay[range.start]!;
      result['date'] = range.start;
      result['totals'] = d.toJson();
      if (profile != null) result['remaining'] = remainingJson(profile, d);
      result['entries'] = [
        for (final e in entries.take(40))
          {
            'id': e.id,
            'name': e.name,
            'meal': e.mealType,
            'calories_kcal': r1(e.calories),
            'protein_g': r1(e.proteinG),
            'carbs_g': r1(e.carbsG),
            'fat_g': r1(e.fatG),
            'grams': ?e.grams == null ? null : r1(e.grams!),
            'servings': r1(e.servings),
            'verification': e.verification,
          },
      ];
    } else {
      final logged = byDay.values.where((d) => d.entries > 0).toList();
      double avg(double Function(DayNutrition) f) => logged.isEmpty
          ? 0
          : logged.map(f).reduce((a, b) => a + b) / logged.length;
      result['days'] = {for (final e in byDay.entries) e.key: e.value.toJson()};
      result['days_logged'] = logged.length;
      result['average_per_logged_day'] = {
        'calories_kcal': r1(avg((d) => d.calories)),
        'protein_g': r1(avg((d) => d.protein)),
        'carbs_g': r1(avg((d) => d.carbs)),
        'fat_g': r1(avg((d) => d.fat)),
      };
    }
    result['missing'] = missing.take(31).toList();
    result['provenance'] = provenance(
      sources: sources.isEmpty ? ['Food log'] : sources,
      asOf: entries.isEmpty ? null : entries.last.updatedAt,
      range: range,
      note: 'Totals computed on-device from logged entries.',
    );
    return result;
  },
);

final searchFoodDatabaseTool = ToolSpec(
  name: 'search_food_database',
  description:
      "Searches the user's saved food database on this device (not the "
      'internet) by name or brand. Returns per-serving nutrients and food ids '
      'that can be passed to log_food.',
  inputSchema: S.object(
    {
      'query': S.str('Food name to search for.', minLength: 2, maxLength: 80),
      'limit': S.integer('Max results (default 8).', minimum: 1, maximum: 20),
    },
    required: ['query'],
  ),
  chipLabel: (a, now) => 'Searched foods · "${a['query'] ?? ''}"',
  handler: (ctx, args) async {
    final q = (args['query'] as String).trim().toLowerCase();
    final limit = (args['limit'] as num?)?.toInt() ?? 8;
    final pattern = '%${q.replaceAll('%', '').replaceAll('_', '')}%';
    final rows =
        await (ctx.db.select(ctx.db.foods)
              ..where(
                (f) =>
                    f.deletedAt.isNull() &
                    (f.name.lower().like(pattern) |
                        f.brand.lower().like(pattern)),
              )
              ..orderBy([
                (f) => OrderingTerm.desc(f.isFavorite),
                (f) => OrderingTerm.asc(f.name),
              ])
              ..limit(limit))
            .get();
    return {
      'query': q,
      'results': [
        for (final f in rows)
          {
            'food_id': f.id,
            'name': f.name,
            'brand': ?f.brand,
            'serving': '${r1(f.servingSize)} ${f.servingUnit}',
            'grams_per_serving': ?f.gramsPerServing == null
                ? null
                : r1(f.gramsPerServing!),
            'calories_kcal': r1(f.calories),
            'protein_g': r1(f.proteinG),
            'carbs_g': r1(f.carbsG),
            'fat_g': r1(f.fatG),
            'verification': f.verification,
            'source': sourceLabel(f.source),
          },
      ],
      'missing': [if (rows.isEmpty) 'no matching foods in the local database'],
      'provenance': provenance(
        sources: rows.map((f) => sourceLabel(f.source)),
        note: 'Local food database only.',
      ),
    };
  },
);

const mealTypes = ['breakfast', 'lunch', 'dinner', 'snack'];

final _foodItemSchema = S.object(
  {
    'name': S.str('Food name.', minLength: 1, maxLength: 120),
    'food_id': S.str(
      'Id from search_food_database, if matched.',
      maxLength: 64,
    ),
    'grams': S.number('Amount in grams.', minimum: 1, maximum: 5000),
    'servings': S.number('Number of servings.', minimum: 0.1, maximum: 50),
    'calories': S.number(
      'Total kcal for this item (required without food_id).',
      minimum: 0,
      maximum: 5000,
    ),
    'protein_g': S.number('Protein grams.', minimum: 0, maximum: 500),
    'carbs_g': S.number('Carbohydrate grams.', minimum: 0, maximum: 1000),
    'fat_g': S.number('Fat grams.', minimum: 0, maximum: 500),
    'fiber_g': S.number('Fiber grams.', minimum: 0, maximum: 200),
  },
  required: ['name'],
);

/// Nutrient snapshot for one item (scaled from a stored food when matched).
class _Snapshot {
  _Snapshot(this.values, {this.food});
  final Map<String, double?> values;
  final Food? food;
}

Future<_Snapshot> _snapshotFor(
  AppDatabase db,
  Map<String, Object?> item,
) async {
  final foodId = item['food_id'] as String?;
  final grams = (item['grams'] as num?)?.toDouble();
  final servings = (item['servings'] as num?)?.toDouble();
  if (foodId != null) {
    final food =
        await (db.select(db.foods)
              ..where((f) => f.id.equals(foodId) & f.deletedAt.isNull()))
            .getSingleOrNull();
    if (food == null) {
      throw ArgumentError('food_id "$foodId" was not found.');
    }
    double factor;
    if (grams != null && food.gramsPerServing != null) {
      factor = grams / food.gramsPerServing!;
    } else if (grams != null && food.servingUnit == 'g') {
      factor = grams / food.servingSize;
    } else if (grams != null) {
      throw ArgumentError(
        '${food.name} has no gram weight per serving; use servings.',
      );
    } else {
      factor = servings ?? 1;
    }
    return _Snapshot({
      'calories': food.calories * factor,
      'protein': food.proteinG * factor,
      'carbs': food.carbsG * factor,
      'fat': food.fatG * factor,
      'fiber': food.fiberG == null ? null : food.fiberG! * factor,
      'grams':
          grams ??
          (food.gramsPerServing == null
              ? null
              : food.gramsPerServing! * factor),
      'servings': grams == null ? factor : null,
    }, food: food);
  }
  final calories = (item['calories'] as num?)?.toDouble();
  if (calories == null) {
    throw ArgumentError(
      'Item "${item['name']}" needs calories (or a food_id).',
    );
  }
  return _Snapshot({
    'calories': calories,
    'protein': (item['protein_g'] as num?)?.toDouble() ?? 0,
    'carbs': (item['carbs_g'] as num?)?.toDouble() ?? 0,
    'fat': (item['fat_g'] as num?)?.toDouble() ?? 0,
    'fiber': (item['fiber_g'] as num?)?.toDouble(),
    'grams': grams,
    'servings': servings ?? 1,
  });
}

DateTime _loggedAtFor(String date, ToolContext ctx) {
  if (date == ctx.today) return ctx.now;
  final d = LocalDates.parse(date);
  return DateTime(d.year, d.month, d.day, 12);
}

String _checkNotFuture(String? date, ToolContext ctx) {
  final d = date ?? ctx.today;
  if (d.compareTo(ctx.today) > 0) {
    throw ArgumentError('Cannot log for a future date ($d).');
  }
  return d;
}

final logFoodTool = ToolSpec(
  name: 'log_food',
  description:
      'Logs one or more food items to a meal. Requires user approval (a '
      'confirmation card is shown). Items without a food_id are saved as '
      'estimates; include your best kcal/macro estimate for them.',
  inputSchema: S.object(
    {
      'date': S.date('Local date YYYY-MM-DD (default today, not future).'),
      'meal_type': S.str('Meal.', enumValues: mealTypes),
      'items': S.array(
        'Food items.',
        _foodItemSchema,
        minItems: 1,
        maxItems: 10,
      ),
      'note': S.str('Optional note.', maxLength: 200),
    },
    required: ['meal_type', 'items'],
  ),
  isWrite: true,
  consent: ToolConsent.health,
  confirmTitle: 'Log food',
  confirmSummary: (a) {
    final items = (a['items'] as List? ?? const []).cast<Map>();
    return [
      '${a['meal_type']} · ${a['date'] ?? 'today'}',
      for (final i in items)
        '${i['name']}'
            '${i['grams'] != null ? ' · ${i['grams']} g' : ''}'
            '${i['servings'] != null ? ' · ${i['servings']} serving(s)' : ''}'
            '${i['calories'] != null ? ' · ${i['calories']} kcal' : ''}'
            '${i['protein_g'] != null ? ' · P ${i['protein_g']} g' : ''}'
            '${i['food_id'] == null ? ' (estimate)' : ''}',
    ];
  },
  chipLabel: (a, now) => 'Logged food · ${chipRange(a, now)}',
  handler: (ctx, args) async {
    final date = _checkNotFuture(args['date'] as String?, ctx);
    final meal = args['meal_type'] as String;
    final items = (args['items'] as List).cast<Map>().map(
      (m) => m.cast<String, Object?>(),
    );
    final loggedAt = _loggedAtFor(date, ctx);
    final logged = <Map<String, Object?>>[];
    var i = 0;
    await ctx.db.transaction(() async {
      for (final item in items) {
        final snap = await _snapshotFor(ctx.db, item);
        final v = snap.values;
        final id = stableId('ai_tool_food', '${ctx.idempotencyKey}#$i');
        i++;
        await ctx.db
            .into(ctx.db.foodLogEntries)
            .insert(
              FoodLogEntriesCompanion.insert(
                id: id,
                foodId: Value(snap.food?.id),
                name: snap.food?.name ?? (item['name'] as String),
                brand: Value(snap.food?.brand),
                mealType: meal,
                servings: Value(v['servings'] ?? 1),
                grams: Value(v['grams']),
                calories: v['calories']!,
                proteinG: Value(v['protein']!),
                carbsG: Value(v['carbs']!),
                fatG: Value(v['fat']!),
                fiberG: Value(v['fiber']),
                source: snap.food?.source ?? 'ai_estimate',
                verification: snap.food?.verification ?? 'estimate',
                loggedAt: loggedAt.toUtc(),
                localDate: date,
                tzName: ctx.now.timeZoneName,
                note: Value(args['note'] as String?),
              ),
              mode: InsertMode.insertOrIgnore,
            );
        logged.add({
          'id': id,
          'name': snap.food?.name ?? item['name'],
          'calories_kcal': r1(v['calories']!),
          'protein_g': r1(v['protein']!),
          'verification': snap.food?.verification ?? 'estimate',
        });
      }
    });
    final range = DateRange(date, date);
    final day = totalsByDay(await foodEntries(ctx.db, range), range)[date]!;
    final profile = await loadProfile(ctx.db);
    return {
      'status': 'logged',
      'date': date,
      'meal_type': meal,
      'logged': logged,
      'day_totals': day.toJson(),
      'remaining': ?profile == null ? null : remainingJson(profile, day),
      'provenance': provenance(
        sources: ['Food log'],
        asOf: ctx.now,
        range: range,
        note: 'Items without a matched food are saved as estimates.',
      ),
    };
  },
);

final updateFoodEntryTool = ToolSpec(
  name: 'update_food_entry',
  description:
      'Changes an existing food log entry (amount, meal or nutrients). '
      'Requires user approval. Get entry ids from get_nutrition_summary.',
  inputSchema: S.object(
    {
      'entry_id': S.str('Food log entry id.', minLength: 1, maxLength: 64),
      'meal_type': S.str('New meal.', enumValues: mealTypes),
      'grams': S.number('New amount in grams.', minimum: 1, maximum: 5000),
      'servings': S.number('New servings.', minimum: 0.1, maximum: 50),
      'calories': S.number('New kcal.', minimum: 0, maximum: 5000),
      'protein_g': S.number('New protein g.', minimum: 0, maximum: 500),
      'carbs_g': S.number('New carbs g.', minimum: 0, maximum: 1000),
      'fat_g': S.number('New fat g.', minimum: 0, maximum: 500),
    },
    required: ['entry_id'],
  ),
  isWrite: true,
  consent: ToolConsent.health,
  confirmTitle: 'Update food entry',
  confirmSummary: (a) => [
    for (final e in a.entries)
      if (e.key != 'entry_id') '${e.key.replaceAll('_', ' ')} → ${e.value}',
  ],
  chipLabel: (a, now) => 'Updated food entry',
  handler: (ctx, args) async {
    final id = args['entry_id'] as String;
    final entry = await (ctx.db.select(
      ctx.db.foodLogEntries,
    )..where((f) => f.id.equals(id) & f.deletedAt.isNull())).getSingleOrNull();
    if (entry == null) throw ArgumentError('Food entry "$id" was not found.');
    final grams = (args['grams'] as num?)?.toDouble();
    final servings = (args['servings'] as num?)?.toDouble();
    final explicit = [
      'calories',
      'protein_g',
      'carbs_g',
      'fat_g',
    ].any(args.containsKey);
    var companion = FoodLogEntriesCompanion(
      updatedAt: Value(ctx.now.toUtc()),
      mealType: args['meal_type'] == null
          ? const Value.absent()
          : Value(args['meal_type'] as String),
    );
    if ((grams != null || servings != null) &&
        !explicit &&
        entry.foodId != null) {
      final snap = await _snapshotFor(ctx.db, {
        'name': entry.name,
        'food_id': entry.foodId,
        'grams': ?grams,
        'servings': ?servings,
      });
      final v = snap.values;
      companion = companion.copyWith(
        grams: Value(v['grams']),
        servings: Value(v['servings'] ?? entry.servings),
        calories: Value(v['calories']!),
        proteinG: Value(v['protein']!),
        carbsG: Value(v['carbs']!),
        fatG: Value(v['fat']!),
        fiberG: Value(v['fiber']),
      );
    } else {
      // A new amount without explicit nutrients rescales the snapshot: by
      // grams when both are known, otherwise by servings.
      final scale = explicit
          ? null
          : entry.grams != null && grams != null
          ? grams / entry.grams!
          : grams == null && servings != null && entry.servings > 0
          ? servings / entry.servings
          : null;
      companion = companion.copyWith(
        grams: grams == null ? const Value.absent() : Value(grams),
        servings: servings == null ? const Value.absent() : Value(servings),
        calories: Value(
          (args['calories'] as num?)?.toDouble() ??
              entry.calories * (scale ?? 1),
        ),
        proteinG: Value(
          (args['protein_g'] as num?)?.toDouble() ??
              entry.proteinG * (scale ?? 1),
        ),
        carbsG: Value(
          (args['carbs_g'] as num?)?.toDouble() ?? entry.carbsG * (scale ?? 1),
        ),
        fatG: Value(
          (args['fat_g'] as num?)?.toDouble() ?? entry.fatG * (scale ?? 1),
        ),
        verification: explicit || scale != null
            ? const Value('estimate')
            : const Value.absent(),
      );
    }
    await (ctx.db.update(
      ctx.db.foodLogEntries,
    )..where((f) => f.id.equals(id))).write(companion);
    final after = await (ctx.db.select(
      ctx.db.foodLogEntries,
    )..where((f) => f.id.equals(id))).getSingle();
    return {
      'status': 'updated',
      'entry': {
        'id': after.id,
        'name': after.name,
        'meal': after.mealType,
        'calories_kcal': r1(after.calories),
        'protein_g': r1(after.proteinG),
        'carbs_g': r1(after.carbsG),
        'fat_g': r1(after.fatG),
        'verification': after.verification,
      },
      'before': {
        'calories_kcal': r1(entry.calories),
        'protein_g': r1(entry.proteinG),
      },
      'provenance': provenance(
        sources: ['Food log'],
        asOf: ctx.now,
        range: DateRange(after.localDate, after.localDate),
      ),
    };
  },
);

final getWaterSummaryTool = ToolSpec(
  name: 'get_water_summary',
  description:
      'Water intake in ml for a day or range (max 31 days) with the daily '
      'goal and amount remaining today.',
  inputSchema: S.object(dateRangeProps()),
  consent: ToolConsent.health,
  chipLabel: (a, now) => 'Read water · ${chipRange(a, now)}',
  handler: (ctx, args) async {
    final range = resolveRange(args, ctx.today);
    final totals = await ctx.water.totalsByDay(range.start, range.end);
    final profile = await loadProfile(ctx.db);
    final goal = profile?.waterGoalMl ?? 3000;
    final rows =
        await (ctx.db.select(ctx.db.waterLogs)..where(
              (w) =>
                  w.localDate.isBetweenValues(range.start, range.end) &
                  w.deletedAt.isNull(),
            ))
            .get();
    return {
      'goal_ml': goal,
      'days': {
        for (final e in totals.entries)
          e.key: {'total_ml': e.value, 'remaining_ml': goal - e.value},
      },
      'missing': [
        for (final e in totals.entries)
          if (e.value == 0) 'no water logged on ${e.key}',
      ],
      'provenance': provenance(
        sources: rows.isEmpty
            ? ['Water log']
            : rows.map((r) => sourceLabel(r.source)),
        asOf: rows.isEmpty
            ? null
            : rows
                  .map((r) => r.loggedAt)
                  .reduce((a, b) => a.isAfter(b) ? a : b),
        range: range,
      ),
    };
  },
);

final logWaterTool = ToolSpec(
  name: 'log_water',
  description: 'Logs water the user drank now. Requires user approval.',
  inputSchema: S.object(
    {'amount_ml': S.integer('Amount in ml.', minimum: 50, maximum: 2000)},
    required: ['amount_ml'],
  ),
  isWrite: true,
  consent: ToolConsent.health,
  confirmTitle: 'Log water',
  confirmSummary: (a) => ['${a['amount_ml']} ml · now'],
  chipLabel: (a, now) => 'Logged water · ${a['amount_ml']} ml',
  handler: (ctx, args) async {
    final amount = (args['amount_ml'] as num).toInt();
    await ctx.water.add(
      amount,
      source: 'ai',
      at: ctx.now,
      id: stableId('ai_tool_water', ctx.idempotencyKey),
    );
    final totals = await ctx.water.totalsByDay(ctx.today, ctx.today);
    final goal = (await loadProfile(ctx.db))?.waterGoalMl ?? 3000;
    final total = totals[ctx.today] ?? 0;
    return {
      'status': 'logged',
      'amount_ml': amount,
      'today_total_ml': total,
      'goal_ml': goal,
      'remaining_ml': goal - total,
      'provenance': provenance(sources: ['Water log'], asOf: ctx.now),
    };
  },
);
