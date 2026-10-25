import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/domain/provenance.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/util/format.dart';
import '../../domain/food_models.dart';
import '../../domain/nutrients.dart';

DataOrigin originForSource(String source) => switch (source) {
  FoodSources.openFoodFacts => DataOrigin.openFoodFacts,
  FoodSources.usda => DataOrigin.usda,
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

/// Visible ESTIMATE pill. Use wherever estimated values are displayed.
class EstimateBadge extends StatelessWidget {
  const EstimateBadge({super.key, this.label = 'ESTIMATE'});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Estimated values',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.15),
          borderRadius: AppRadii.chip,
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: AppColors.warning,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
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
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (verification) {
      Verifications.verifiedLabel => Icons.qr_code_2,
      Verifications.database => Icons.storage_outlined,
      _ => Icons.edit_outlined,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          Verifications.label(verification),
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
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
      style: Theme.of(context).textTheme.labelSmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}

/// Prev / label / next date switcher with a "Today" shortcut.
class DateSwitcher extends StatelessWidget {
  const DateSwitcher({
    super.key,
    required this.date,
    required this.today,
    required this.onChanged,
    this.allowFuture = false,
  });

  final String date;
  final String today;
  final ValueChanged<String> onChanged;
  final bool allowFuture;

  @override
  Widget build(BuildContext context) {
    final canNext = allowFuture || date.compareTo(today) < 0;
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        IconButton(
          tooltip: 'Previous day',
          icon: const Icon(Icons.chevron_left),
          onPressed: () => onChanged(LocalDates.addDays(date, -1)),
        ),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Text(
              friendlyDate(date, today),
              textAlign: TextAlign.center,
              style: t.titleMedium,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Next day',
          icon: const Icon(Icons.chevron_right),
          onPressed: canNext
              ? () => onChanged(LocalDates.addDays(date, 1))
              : null,
        ),
        if (date != today)
          TextButton(
            onPressed: () => onChanged(today),
            child: const Text('Today'),
          )
        else
          const SizedBox(width: AppSpacing.sm),
      ],
    );
  }
}

/// Compact nutrient preview row used in sheets.
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
    Widget cell(String label, String value, Color color) => Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: t.titleMedium?.copyWith(color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(label, style: t.labelSmall),
        ],
      ),
    );
    return Semantics(
      label:
          'Preview: ${macroSummary(nutrients, fiber: true)}'
          '${estimate ? ', estimate' : ''}',
      excludeSemantics: true,
      child: Row(
        children: [
          cell('kcal', Fmt.integer(nutrients.calories), AppColors.calories),
          cell('protein', Fmt.grams(nutrients.protein), AppColors.protein),
          cell('carbs', Fmt.grams(nutrients.carbs), AppColors.carbs),
          cell('fat', Fmt.grams(nutrients.fat), AppColors.fat),
          if (nutrients.fiber != null)
            cell('fiber', Fmt.grams(nutrients.fiber!), AppColors.fiber),
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
