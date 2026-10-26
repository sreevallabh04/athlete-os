import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/food_lookup_service.dart';
import '../application/providers.dart';
import '../data/mappers.dart';
import '../domain/food_models.dart';
import 'barcode_scan_screen.dart';
import 'custom_food_screen.dart';
import 'label_scan_screen.dart';
import 'widgets/amount_sheet.dart';
import 'widgets/common.dart';

/// Shared flows used by the Add food screen tabs.

/// Amount sheet → log a local food.
Future<bool> logLocalFood(
  BuildContext context,
  WidgetRef ref, {
  required Food food,
  required MealType meal,
  required String date,
}) async {
  final res = await showAmountSheet(
    context,
    title: food.name,
    subtitle: food.brand,
    basis: food.basis,
    verification: food.verification,
    origin: originForSource(food.source),
    initialMeal: meal,
    showOffAttribution: food.source == FoodSources.openFoodFacts,
  );
  if (res == null) return false;
  try {
    await ref
        .read(foodLogRepositoryProvider)
        .logFood(
          food,
          amount: res.amount,
          mealType: res.meal ?? meal,
          localDate: date,
        );
    Haptics.success();
    if (context.mounted) {
      showSnack(context, 'Logged ${food.name} to ${(res.meal ?? meal).label}');
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      showSnack(context, 'Could not log: ${redactSecrets(e.toString())}');
    }
    return false;
  }
}

/// Review a remote (OFF/USDA) result. Complete data → amount sheet → saved
/// locally + logged. Incomplete data → manual completion form.
Future<bool> openCandidate(
  BuildContext context,
  WidgetRef ref, {
  required FoodCandidate candidate,
  required MealType meal,
  required String date,
  bool fromBarcode = false,
}) async {
  final isOff = candidate.source == FoodSources.openFoodFacts;
  final verification = fromBarcode && isOff
      ? Verifications.verifiedLabel
      : Verifications.database;
  final basis = candidate.toBasis();
  if (basis == null) {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Incomplete nutrition data'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${candidate.name} is missing: '
              '${candidate.missingNutrients.join(', ')}.\n\n'
              'The app will not guess these values. Check the package label '
              'and enter them yourself.',
            ),
            if (isOff) ...[const SizedBox(height: 12), const OffAttribution()],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Enter from label'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return false;
    final food = await Navigator.of(context).push<Food>(
      MaterialPageRoute(builder: (_) => CustomFoodScreen(prefill: candidate)),
    );
    if (food == null || !context.mounted) return false;
    return logLocalFood(context, ref, food: food, meal: meal, date: date);
  }

  final res = await showAmountSheet(
    context,
    title: candidate.name,
    subtitle: candidate.brand,
    basis: basis,
    verification: verification,
    origin: originForSource(candidate.source),
    initialMeal: meal,
    actionLabel: 'Save & log',
    showOffAttribution: isOff,
    extra: candidate.energyFromKj
        ? const Text('Calories converted from kJ (1 kcal = 4.184 kJ).')
        : null,
  );
  if (res == null) return false;
  try {
    final food = await ref
        .read(foodRepositoryProvider)
        .saveCandidate(candidate, verification: verification);
    await ref
        .read(foodLogRepositoryProvider)
        .logFood(
          food,
          amount: res.amount,
          mealType: res.meal ?? meal,
          localDate: date,
        );
    Haptics.success();
    if (context.mounted) {
      showSnack(context, 'Logged ${food.name} to ${(res.meal ?? meal).label}');
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      showSnack(context, 'Could not log: ${redactSecrets(e.toString())}');
    }
    return false;
  }
}

/// Scan → local lookup → Open Food Facts → review → log.
Future<void> runBarcodeFlow(
  BuildContext context,
  WidgetRef ref, {
  required MealType meal,
  required String date,
}) async {
  // Root navigator: the scanner is full-screen chrome (never under the dock).
  final code = await Navigator.of(
    context,
    rootNavigator: true,
  ).push<String>(MaterialPageRoute(builder: (_) => const BarcodeScanScreen()));
  if (code == null || !context.mounted) return;
  await lookupAndLogBarcode(context, ref, code: code, meal: meal, date: date);
}

Future<void> lookupAndLogBarcode(
  BuildContext context,
  WidgetRef ref, {
  required String code,
  required MealType meal,
  required String date,
}) async {
  showSnack(context, 'Looking up $code…');
  final result = await ref.read(foodLookupServiceProvider).lookupBarcode(code);
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
  switch (result) {
    case BarcodeLocalHit(:final food):
      await logLocalFood(context, ref, food: food, meal: meal, date: date);
    case BarcodeRemoteHit(:final candidate):
      await openCandidate(
        context,
        ref,
        candidate: candidate,
        meal: meal,
        date: date,
        fromBarcode: true,
      );
    case BarcodeNotFound():
      await _offerManual(
        context,
        ref,
        code: code,
        meal: meal,
        date: date,
        title: 'Product not found',
        message:
            'Barcode $code is not in Open Food Facts yet. Scan the nutrition '
            'table on the pack (or type it) and it is saved to My foods, so '
            'this barcode finds it instantly next time.',
      );
    case BarcodeLookupFailed(:final message):
      await _offerManual(
        context,
        ref,
        code: code,
        meal: meal,
        date: date,
        title: 'Lookup failed',
        message: message,
      );
  }
}

enum _NotFoundChoice { label, manual }

Future<void> _offerManual(
  BuildContext context,
  WidgetRef ref, {
  required String code,
  required MealType meal,
  required String date,
  required String title,
  required String message,
}) async {
  final choice = await showDialog<_NotFoundChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actionsOverflowButtonSpacing: 4,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('barcode-enter-manually'),
          onPressed: () => Navigator.pop(ctx, _NotFoundChoice.manual),
          child: const Text('Enter manually'),
        ),
        FilledButton.icon(
          key: const Key('barcode-scan-label'),
          onPressed: () => Navigator.pop(ctx, _NotFoundChoice.label),
          icon: const Icon(Icons.document_scanner_outlined, size: 18),
          label: const Text('Scan nutrition label'),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == _NotFoundChoice.label) {
    // The label screen offers "Save & log" itself; "Save" only saves.
    await openLabelScan(context, barcode: code, meal: meal, date: date);
    return;
  }
  final food = await Navigator.of(context).push<Food>(
    MaterialPageRoute(builder: (_) => CustomFoodScreen(barcode: code)),
  );
  if (food == null || !context.mounted) return;
  await logLocalFood(context, ref, food: food, meal: meal, date: date);
}
