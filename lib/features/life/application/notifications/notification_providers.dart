import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/paths.dart';
import '../../../../core/contracts/calendar_reader.dart';
import '../../../../core/time/clock.dart';
import '../../../../data/providers.dart';
import '../../domain/reminder_kinds.dart';
import '../../domain/reminder_scheduler.dart';
import '../../../../data/repositories/settings_repository.dart';
import '../../data/watch_tables.dart';
import '../habit_providers.dart';
import 'notification_actions.dart';
import 'notification_gateway.dart';
import 'reminder_service.dart';

final notificationGatewayProvider = Provider<NotificationGateway>(
  (ref) =>
      FlnNotificationGateway(backgroundHandler: notificationBackgroundHandler),
);

final reminderServiceProvider = Provider<ReminderService>((ref) {
  final service = ReminderService(
    gateway: ref.watch(notificationGatewayProvider),
    db: ref.watch(databaseProvider),
    clock: ref.watch(clockProvider),
    calendarReader: ref.watch(calendarReaderProvider),
    habitBoardLoader: ref.watch(habitBoardLoaderProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Emits whenever data that affects reminders changes (prefs, habits,
/// completions, settings, profile, competition milestones).
final reminderInputsChangedProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  var n = 0;
  return watchTables(db, [
    db.notificationPrefs,
    db.habits,
    db.habitCompletions,
    db.appSettings,
    db.userProfiles,
    db.competitions,
    db.competitionMilestones,
  ], () async => n++);
});

/// Snapshot of the notification permission state for the settings UI.
class NotificationPermissionState {
  const NotificationPermissionState({
    required this.enabled,
    required this.exactAllowed,
  });

  /// Null = unknown (e.g. not on Android).
  final bool? enabled;
  final bool? exactAllowed;
}

final notificationPermissionProvider =
    FutureProvider<NotificationPermissionState>((ref) async {
      final g = ref.watch(notificationGatewayProvider);
      bool? enabled;
      bool? exact;
      try {
        enabled = await g.notificationsEnabled();
        exact = await g.canScheduleExact();
      } catch (_) {}
      return NotificationPermissionState(enabled: enabled, exactAllowed: exact);
    });

final quietHoursProvider = StreamProvider<QuietHours?>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watch<Object?>(SettingKeys.quietHours)
      .map(QuietHours.fromJson),
);

final calendarAwareRemindersProvider = StreamProvider<bool>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watch<bool>(SettingKeys.calendarAwareReminders)
      .map((v) => v ?? false),
);

/// Where a notification tap should navigate.
String? routeForPayload(String? payload) {
  if (payload == null) return null;
  try {
    final m = jsonDecode(payload);
    if (m is! Map) return null;
    final kind = ReminderKind.fromKey('${m['k']}');
    return switch (kind) {
      ReminderKind.water => AppPaths.hydration,
      ReminderKind.habit => AppPaths.habits,
      ReminderKind.planning || ReminderKind.eodReview => AppPaths.planner,
      ReminderKind.mood => AppPaths.mood,
      ReminderKind.journal => AppPaths.journal,
      ReminderKind.meal => AppPaths.nutrition,
      ReminderKind.weeklySummary => AppPaths.reports,
      ReminderKind.workout => AppPaths.train,
      ReminderKind.steps => AppPaths.steps,
      ReminderKind.competition || ReminderKind.posing => AppPaths.competition,
      null => null,
    };
  } catch (_) {
    return null;
  }
}

/// Tab roots are switched to with `go`; everything else is pushed.
const tabRootPaths = {
  AppPaths.today,
  AppPaths.train,
  AppPaths.nutrition,
  AppPaths.coach,
  AppPaths.life,
};
