import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/redact.dart';
import 'application/persona_providers.dart';
import 'data/nutrition_adjustment_service.dart';

/// Loads the first-launch gate before the first frame (so the router can
/// redirect to `/onboarding`) and, once calibrated, runs the weekly
/// nutrition check-in in the background (proposal only, never applied).
Future<void> onboardingBootstrap(ProviderContainer container) async {
  final gate = container.read(onboardingGateProvider.notifier);
  await gate.load();
  if (container.read(onboardingGateProvider) != true) return;
  unawaited(
    container
        .read(nutritionAdjustmentServiceProvider)
        .evaluate()
        .then<void>(
          (_) {},
          onError: (Object e) => debugPrint(
            'Nutrition check-in skipped: ${redactSecrets(e.toString())}',
          ),
        ),
  );
}
