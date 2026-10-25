/// Where a value came from. Every metric shown in the UI should carry one so
/// the user can always tell measured, imported, manual and estimated data apart.
enum DataOrigin {
  healthConnect('Health Connect'),
  samsungHealth('Samsung Health'),
  manual('Manual'),
  hevy('Hevy'),
  strava('Strava'),
  googleCalendar('Google Calendar'),
  openFoodFacts('Open Food Facts'),
  usda('USDA FoodData Central'),
  aiEstimate('AI estimate'),
  calculated('Calculated'),
  sample('Sample data');

  const DataOrigin(this.label);
  final String label;

  static DataOrigin fromKey(String key) => switch (key) {
    'health_connect' => healthConnect,
    'samsung_health' => samsungHealth,
    'hevy' => hevy,
    'strava' => strava,
    'google_calendar' => googleCalendar,
    'openfoodfacts' || 'open_food_facts' => openFoodFacts,
    'usda' => usda,
    'ai_estimate' || 'ai' => aiEstimate,
    'calculated' => calculated,
    'sample' => sample,
    _ => manual,
  };
}

enum Freshness { live, recent, stale, unknown }

/// Value + provenance wrapper used by dashboards and AI tools.
class Sourced<T> {
  const Sourced(
    this.value, {
    required this.origin,
    this.asOf,
    this.isEstimate = false,
    this.note,
  });

  final T value;
  final DataOrigin origin;

  /// When the value was last measured/synced. Null if unknown.
  final DateTime? asOf;
  final bool isEstimate;
  final String? note;

  Freshness freshness(
    DateTime now, {
    Duration staleAfter = const Duration(hours: 3),
  }) {
    if (asOf == null) return Freshness.unknown;
    final age = now.difference(asOf!);
    if (age < const Duration(minutes: 5)) return Freshness.recent;
    if (age > staleAfter) return Freshness.stale;
    return Freshness.recent;
  }

  Map<String, Object?> provenanceJson() => {
    'source': origin.label,
    if (asOf != null) 'as_of': asOf!.toUtc().toIso8601String(),
    if (isEstimate) 'estimate': true,
    if (note != null) 'note': note,
  };
}
