import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../../data/repositories/settings_repository.dart';
import '../data/health_connect_data_source.dart';
import '../data/health_data_source.dart';
import '../data/health_repository.dart';
import '../data/health_settings.dart';
import '../domain/health_types.dart';
import '../domain/steps_math.dart';
import 'health_sync_service.dart';

/// Health Connect gateway. Override with [FakeHealthDataSource] in tests.
final healthDataSourceProvider = Provider<HealthDataSource>(
  (ref) => HealthConnectDataSource(),
);

final healthRepositoryProvider = Provider<HealthRepository>(
  (ref) =>
      HealthRepository(ref.watch(databaseProvider), ref.watch(clockProvider)),
);

final healthSettingsProvider = Provider<HealthSettings>(
  (ref) => HealthSettings(ref.watch(settingsRepositoryProvider)),
);

final healthSyncServiceProvider = Provider<HealthSyncService>((ref) {
  final service = HealthSyncService(
    source: ref.watch(healthDataSourceProvider),
    repository: ref.watch(healthRepositoryProvider),
    status: ref.watch(integrationStatusRepositoryProvider),
    settings: ref.watch(healthSettingsProvider),
    clock: ref.watch(clockProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// True while a Health Connect sync is running.
final healthSyncingProvider = StreamProvider<bool>((ref) async* {
  final service = ref.watch(healthSyncServiceProvider);
  yield service.isSyncing;
  yield* service.syncingChanges;
});

/// Persisted Health Connect status row (last sync, last error, scopes).
final healthConnectionProvider = StreamProvider<IntegrationConnection?>(
  (ref) => ref
      .watch(integrationStatusRepositoryProvider)
      .watch(Providers.healthConnect),
);

final healthEnabledGroupsProvider = StreamProvider<Set<HealthGroup>>(
  (ref) => ref.watch(healthSettingsProvider).watchEnabledGroups(),
);

/// Live device-side diagnostics (SDK status + per-type permissions).
/// Invalidate after permission changes.
class HealthDiagnostics {
  const HealthDiagnostics({
    required this.sdk,
    required this.permissions,
    required this.historyAvailable,
    required this.historyAuthorized,
  });

  final HcSdkStatus sdk;
  final Map<HcDataType, bool> permissions;
  final bool historyAvailable;
  final bool historyAuthorized;

  bool granted(HcDataType t) => permissions[t] ?? false;
  bool groupGranted(HealthGroup g) => g.types.every(granted);
  bool groupPartiallyGranted(HealthGroup g) => g.types.any(granted);
}

final healthDiagnosticsProvider = FutureProvider<HealthDiagnostics>((
  ref,
) async {
  final ds = ref.watch(healthDataSourceProvider);
  final sdk = await ds.sdkStatus();
  final perms = <HcDataType, bool>{};
  if (sdk == HcSdkStatus.available) {
    for (final t in HcDataType.values) {
      perms[t] = await ds.hasPermissions([t]);
    }
  }
  return HealthDiagnostics(
    sdk: sdk,
    permissions: perms,
    historyAvailable: sdk == HcSdkStatus.available
        ? await ds.isHistoryAvailable()
        : false,
    historyAuthorized: sdk == HcSdkStatus.available
        ? await ds.isHistoryAuthorized()
        : false,
  );
});

/// Resolved steps for the last [days] days (inclusive of today), keyed by
/// local date. Null values mean "no data for that day".
final stepsHistoryProvider = StreamProvider.family<Map<String, DaySteps?>, int>(
  (ref, days) {
    final today = ref.watch(localDayProvider);
    final start = LocalDates.addDays(today, -(days - 1));
    return ref.watch(healthRepositoryProvider).watchResolvedSteps(start, today);
  },
);

/// Today's resolved steps (HC preferred over manual). For other features
/// (Today dashboard, habits auto-rule, AI tools, notifications).
final todayStepsProvider = StreamProvider<DaySteps?>((ref) {
  final today = ref.watch(localDayProvider);
  return ref
      .watch(healthRepositoryProvider)
      .watchResolvedSteps(today, today)
      .map((m) => m[today]);
});

/// Daily summaries of [type] for the last N days. Arg: (type, days).
final dailySummariesProvider =
    StreamProvider.family<List<DailyHealthSummary>, (String, int)>((ref, arg) {
      final (type, days) = arg;
      final today = ref.watch(localDayProvider);
      return ref
          .watch(healthRepositoryProvider)
          .watchSummaries(type, LocalDates.addDays(today, -(days - 1)), today);
    });

/// Most recent samples of a type, newest first. Arg: (type, limit).
final recentSamplesProvider =
    StreamProvider.family<List<HealthSample>, (String, int)>((ref, arg) {
      final (type, limit) = arg;
      return ref
          .watch(healthRepositoryProvider)
          .watchSamples(type, limit: limit);
    });

/// Weight samples (all origins) for the last 90 days, oldest first.
final weightTrendProvider = StreamProvider<List<HealthSample>>((ref) {
  final since = ref
      .watch(clockProvider)
      .now()
      .subtract(const Duration(days: 90));
  return ref
      .watch(healthRepositoryProvider)
      .watchSamples(HealthKeys.weight, since: since, newestFirst: false);
});
