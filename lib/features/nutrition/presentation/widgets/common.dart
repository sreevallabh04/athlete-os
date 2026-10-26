import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/domain/provenance.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/util/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../domain/food_models.dart';
import '../../domain/nutrients.dart';

DataOrigin originForSource(String source) => switch (source) {
  FoodSources.openFoodFacts => DataOrigin.openFoodFacts,
  FoodSources.usda => DataOrigin.usda,
  FoodSources.indianFoodDb => DataOrigin.indianFoodDb,
  FoodSources.aiEstimate => DataOrigin.aiEstimate,
  FoodSources.recipe => DataOrigin.calculated,
  _ => DataOrigin.manual,
};

/// "Today", "Yesterday", "Tomorrow" or "Sat, 24 Oct".
String friendlyDate(String date, String today) {
  if (date == today) return 'Today';
  if (date == LocalDates.addDays(today, -1)) return 'Yesterday';
  if (date == LocalDates.addDays(today, 1)) return 'Tomorrow';
  final d = LocalDates.parse(date);
  final sameYear = d.year == LocalDates.parse(today).year;
  return DateFormat(sameYear ? 'EEE, d MMM' : 'd MMM y').format(d);
}

String fmtNum(double v) => Fmt.oneDp(v);

/// Number for editable text fields: up to 1 decimal, no grouping separators.
String plainNum(double v) {
  final r = (v * 10).roundToDouble() / 10;
  return r == r.roundToDouble() ? r.toInt().toString() : r.toString();
}

/// "320 kcal · P 24 g · C 30 g · F 9 g".
String macroSummary(Nutrients n, {bool fiber = false}) {
  final parts = [
    Fmt.kcal(n.calories),
    'P ${Fmt.grams(n.protein)}',
    'C ${Fmt.grams(n.carbs)}',
    'F ${Fmt.grams(n.fat)}',
    if (fiber && n.fiber != null) 'Fiber ${Fmt.grams(n.fiber!)}',
  ];
  return parts.join(' · ');
}

/// Amount label for a log entry: "150 g", "1.5 servings".
String amountLabel(double servings, double? grams, {String unit = 'g'}) {
  if (grams != null && grams > 0) return '${Fmt.oneDp(grams)} $unit';
  final s = Fmt.oneDp(servings);
  return servings == 1 ? '1 serving' : '$s servings';
}

/// Icon for a meal slot.
IconData mealIcon(MealType m) => switch (m) {
  MealType.breakfast => Icons.wb_twilight_rounded,
  MealType.lunch => Icons.rice_bowl_outlined,
  MealType.dinner => Icons.nightlight_outlined,
  MealType.snack => Icons.cookie_outlined,
};

/// Visible amber ESTIMATE pill. Use wherever estimated values are shown.
class EstimateBadge extends StatelessWidget {
  const EstimateBadge({super.key, this.label = 'ESTIMATE'});
  final String label;

  @override
  Widget build(BuildContext context) {
    // Amber text darkened on porcelain so it stays readable (AA).
    final ink = context.hud.ink(AppColors.warning);
    return Semantics(
      label: 'Estimated values',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(5, 2, 6, 2),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadii.xs),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_outlined, size: 10, color: ink),
            const SizedBox(width: 3),
            Text(label, style: AppTypography.hudLabel(ink, size: 10.5)),
          ],
        ),
      ),
    );
  }
}

/// Small verification label, e.g. "Label (barcode)" with a matching icon.
class VerificationLabel extends StatelessWidget {
  const VerificationLabel(this.verification, {super.key});
  final String verification;

  @override
  Widget build(BuildContext context) {
    if (Verifications.isEstimate(verification)) return const EstimateBadge();
    final hud = context.hud;
    final verified =
        verification == Verifications.verifiedLabel ||
        verification == Verifications.database;
    final icon = switch (verification) {
      Verifications.verifiedLabel => Icons.verified_outlined,
      Verifications.database => Icons.storage_outlined,
      _ => Icons.edit_outlined,
    };
    final color = verified ? AppColors.success : hud.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            Verifications.label(verification),
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: hud.textMuted),
          ),
        ),
      ],
    );
  }
}

/// Required attribution wherever Open Food Facts data is shown.
class OffAttribution extends StatelessWidget {
  const OffAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      'Data from Open Food Facts (ODbL)',
      style: context.hud.mono(size: 10.5),
    );
  }
}

/// Live macro preview: kcal · protein · carbs · fat (· fiber), each a
/// ticking number over a family-coloured marker.
class NutrientPreview extends StatelessWidget {
  const NutrientPreview({
    super.key,
    required this.nutrients,
    this.estimate = false,
  });
  final Nutrients nutrients;
  final bool estimate;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    Widget cell(String label, String value, Color color) => Expanded(
      child: Column(
        children: [
          AnimatedTicker(
            value,
            duration: AppMotion.long,
            style: t.titleMedium?.copyWith(
              fontFamily: AppFonts.display,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: 18,
            height: 2,
            decoration: BoxDecoration(
              color: color,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.6 * hud.glowStrength),
                  blurRadius: 5,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: hud.label(size: 10),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
    return Semantics(
      label:
          'Preview: ${macroSummary(nutrients, fiber: true)}'
          '${estimate ? ', estimate' : ''}',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          cell('KCAL', Fmt.integer(nutrients.calories), AppColors.calories),
          cell('PROTEIN', Fmt.oneDp(nutrients.protein), AppColors.protein),
          cell('CARBS', Fmt.oneDp(nutrients.carbs), AppColors.carbs),
          cell('FAT', Fmt.oneDp(nutrients.fat), AppColors.fat),
          if (nutrients.fiber != null)
            cell('FIBER', Fmt.oneDp(nutrients.fiber!), AppColors.fiber),
        ],
      ),
    );
  }
}

void showSnack(BuildContext context, String message, {SnackBarAction? action}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), action: action));
}

/// "1.75 L" / "750 ml": hydration needs more precision than `Fmt.ml`.
String preciseMl(int ml) {
  if (ml.abs() < 1000) return '$ml ml';
  var s = (ml / 1000).toStringAsFixed(2);
  s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return '$s L';
}
