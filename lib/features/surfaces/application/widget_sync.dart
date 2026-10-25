import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/clock.dart';
import '../../onboarding/application/persona_providers.dart';
import '../../today/application/today_providers.dart';
import '../data/surfaces_platform.dart';
import '../domain/push_throttle.dart';
import '../domain/widget_snapshot.dart';

/// Minimum spacing between two widget pushes.
const widgetPushInterval = Duration(seconds: 15);

bool _settled(AsyncValue<Object?> v) => v.hasValue || v.hasError;

/// Snapshot for the "JARVIS Today" widget; null until its sources loaded.
///
/// Recomputes whenever the Today snapshot does (food log, water, steps sync,
/// profile targets, workouts — see `TodayRepository.watchedTables`) or the
/// planned session / routine change.
final widgetSnapshotProvider = Provider<WidgetSnapshot?>((ref) {
  final today = ref.watch(todaySnapshotProvider);
  final session = ref.watch(todaysPlannedSessionProvider);
  final routine = ref.watch(todaysRoutineProvider);
  if (!_settled(today) || !_settled(session) || !_settled(routine)) {
    return null;
  }
  return buildWidgetSnapshot(
    now: ref.read(clockProvider).now(),
    today: today.value,
    session: session.value,
    routine: routine.value,
  );
});

/// Pushes snapshots to the native widget store, at most once per
/// [widgetPushInterval] and only when the content changed.
class WidgetSyncService {
  WidgetSyncService(
    SurfacesPlatform platform, {
    Duration interval = widgetPushInterval,
  }) : _throttle = PushThrottle<WidgetSnapshot>(
         interval: interval,
         push: (s) async {
           final ok = await platform.updateWidget(s.encode());
           if (!ok) throw StateError('widget update not delivered');
         },
         keyOf: (s) => s.contentKey(),
       );

  final PushThrottle<WidgetSnapshot> _throttle;

  int get pushes => _throttle.pushes;

  void onSnapshot(WidgetSnapshot? s) {
    if (s != null) _throttle.add(s);
  }

  /// Pushes a coalesced pending snapshot now (app going to background).
  void flush() => _throttle.flush();

  void dispose() => _throttle.dispose();
}

final widgetSyncServiceProvider = Provider<WidgetSyncService>((ref) {
  final s = WidgetSyncService(ref.watch(surfacesPlatformProvider));
  ref.onDispose(s.dispose);
  return s;
});
