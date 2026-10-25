import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/env.dart';
import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../integrations/data/api_errors.dart';
import '../data/cardio_repository.dart';
import '../data/hevy_sync_service.dart';
import '../data/strava_sync_service.dart';
import '../data/workout_repository.dart';
import '../domain/running_analytics.dart';
import '../domain/running_models.dart';
import '../domain/strength_models.dart';

/// All non-deleted strength workouts, newest first.
final workoutLogsProvider = StreamProvider<List<WorkoutLog>>(
  (ref) => ref.watch(workoutRepositoryProvider).watchLogs(),
);

/// All cardio activities (every source), newest first, not deduplicated.
final rawCardioProvider = StreamProvider<List<RunActivity>>(
  (ref) => ref.watch(cardioRepositoryProvider).watchAll(),
);

/// Cardio activities with Strava/Health Connect duplicates merged.
final cardioActivitiesProvider = Provider<AsyncValue<List<RunActivity>>>(
  (ref) => ref.watch(rawCardioProvider).whenData(dedupeActivities),
);

final integrationStatusProvider =
    StreamProvider.family<IntegrationConnection?, String>(
      (ref, provider) =>
          ref.watch(integrationStatusRepositoryProvider).watch(provider),
    );

final todayKeyProvider = Provider<String>((ref) => ref.watch(localDayProvider));

/// Which integrations are currently syncing.
class SyncState {
  const SyncState({this.hevy = false, this.strava = false});
  final bool hevy;
  final bool strava;
  SyncState copyWith({bool? hevy, bool? strava}) =>
      SyncState(hevy: hevy ?? this.hevy, strava: strava ?? this.strava);
}

class SyncController extends Notifier<SyncState> {
  @override
  SyncState build() => const SyncState();

  /// Returns a user-facing message (success summary or redacted error).
  Future<String> syncHevy() async {
    if (state.hevy) return 'Hevy sync already running';
    state = state.copyWith(hevy: true);
    try {
      final r = await ref.read(hevySyncServiceProvider).sync();
      return r.fullImport
          ? 'Imported ${r.upserted} Hevy workouts'
          : 'Hevy: ${r.upserted} updated, ${r.deleted} removed';
    } on IntegrationException catch (e) {
      return e.message;
    } catch (_) {
      return 'Hevy sync failed';
    } finally {
      if (ref.mounted) state = state.copyWith(hevy: false);
    }
  }

  Future<String> syncStrava() async {
    if (!Env.hasStrava) return 'Strava is awaiting credentials';
    if (state.strava) return 'Strava sync already running';
    state = state.copyWith(strava: true);
    try {
      final r = await ref.read(stravaSyncServiceProvider).sync();
      return 'Strava: ${r.upserted} activities synced'
          '${r.removed > 0 ? ', ${r.removed} removed' : ''}';
    } on IntegrationException catch (e) {
      return e.message;
    } catch (_) {
      return 'Strava sync failed';
    } finally {
      if (ref.mounted) state = state.copyWith(strava: false);
    }
  }
}

final syncControllerProvider = NotifierProvider<SyncController, SyncState>(
  SyncController.new,
);

/// Streams for a Strava activity: fetched on demand, kept only in memory.
final stravaStreamsProvider = FutureProvider.autoDispose
    .family<Map<String, List<double>>, String>(
      (ref, localId) => ref.watch(stravaSyncServiceProvider).streams(localId),
    );

bool isConnected(IntegrationConnection? row) =>
    row?.status == ConnectionStates.connected;
