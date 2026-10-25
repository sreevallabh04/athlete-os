import '../../../core/util/redact.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../data/food_api.dart';
import '../data/food_repository.dart';
import '../data/open_food_facts_client.dart';
import '../data/usda_client.dart';
import '../domain/food_models.dart';

sealed class BarcodeLookupResult {
  const BarcodeLookupResult(this.barcode);
  final String barcode;
}

/// Found in the local food table (no network used).
class BarcodeLocalHit extends BarcodeLookupResult {
  const BarcodeLocalHit(super.barcode, this.food);
  final Food food;
}

/// Found on Open Food Facts. [candidate] may be incomplete.
class BarcodeRemoteHit extends BarcodeLookupResult {
  const BarcodeRemoteHit(super.barcode, this.candidate);
  final FoodCandidate candidate;
}

class BarcodeNotFound extends BarcodeLookupResult {
  const BarcodeNotFound(super.barcode);
}

class BarcodeLookupFailed extends BarcodeLookupResult {
  const BarcodeLookupFailed(super.barcode, this.message);
  final String message;
}

class RemoteSearchResult {
  const RemoteSearchResult({
    this.openFoodFacts = const [],
    this.usda = const [],
    this.errors = const [],
    this.usdaConfigured = false,
  });
  final List<FoodCandidate> openFoodFacts;
  final List<FoodCandidate> usda;
  final List<String> errors;
  final bool usdaConfigured;

  bool get isEmpty => openFoodFacts.isEmpty && usda.isEmpty;
}

/// Local-first food lookup that talks to Open Food Facts / USDA and records
/// honest integration status (connected only after a successful call).
class FoodLookupService {
  FoodLookupService({
    required this.foods,
    required this.off,
    required this.usda,
    required this.status,
  });

  final FoodRepository foods;
  final OpenFoodFactsClient off;
  final UsdaClient? usda;
  final IntegrationStatusRepository status;

  Future<BarcodeLookupResult> lookupBarcode(String barcode) async {
    final code = barcode.trim();
    final local = await foods.byBarcode(code);
    if (local != null) return BarcodeLocalHit(code, local);
    try {
      final c = await off.productByBarcode(code);
      await _ok(Providers.openFoodFacts);
      if (c == null) return BarcodeNotFound(code);
      return BarcodeRemoteHit(code, c);
    } on FoodApiException catch (e) {
      await _fail(Providers.openFoodFacts, e);
      return BarcodeLookupFailed(code, e.message);
    }
  }

  /// Searches OFF and (when configured) USDA in parallel. Call on submit only.
  Future<RemoteSearchResult> searchRemote(String query) async {
    final errors = <String>[];
    Future<List<FoodCandidate>> runOff() async {
      try {
        final r = await off.search(query);
        await _ok(Providers.openFoodFacts);
        return r;
      } on FoodApiException catch (e) {
        await _fail(Providers.openFoodFacts, e);
        errors.add('Open Food Facts: ${e.message}');
        return const [];
      }
    }

    Future<List<FoodCandidate>> runUsda() async {
      final u = usda;
      if (u == null) return const [];
      try {
        final r = await u.search(query);
        await _ok(Providers.usda);
        return r;
      } on FoodApiException catch (e) {
        await _fail(Providers.usda, e);
        errors.add('USDA: ${e.message}');
        return const [];
      }
    }

    final results = await Future.wait([runOff(), runUsda()]);
    return RemoteSearchResult(
      openFoodFacts: results[0],
      usda: results[1],
      errors: errors,
      usdaConfigured: usda != null,
    );
  }

  Future<void> _ok(String provider) async {
    try {
      await status.setStatus(provider, ConnectionStates.connected);
    } catch (_) {
      // Status bookkeeping must never break a lookup.
    }
  }

  Future<void> _fail(String provider, FoodApiException e) async {
    // Being offline or hitting our own client-side limit is not a provider
    // failure; only record real API errors.
    if (e.kind == FoodApiErrorKind.offline ||
        e.kind == FoodApiErrorKind.rateLimited ||
        e.kind == FoodApiErrorKind.timeout) {
      return;
    }
    try {
      await status.setStatus(
        provider,
        ConnectionStates.error,
        error: redactSecrets(e.message),
      );
    } catch (_) {}
  }
}
