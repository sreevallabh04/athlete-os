import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/contracts/calendar_reader.dart';
import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../../data/repositories/water_repository.dart';
import '../../health/application/health_providers.dart';
import '../../life/application/habit_providers.dart';
import '../../nutrition/application/providers.dart';
import '../data/assistant_platform.dart';
import '../data/assistant_repository.dart';
import '../domain/assistant_settings.dart';
import '../domain/briefing_builder.dart';
import 'assistant_controller.dart';
import 'briefing_service.dart';
import 'ingestion_service.dart';
import 'reply_drafter.dart';
import 'reply_service.dart';

final assistantRepositoryProvider = Provider<AssistantRepository>(
  (ref) => AssistantRepository(
    ref.watch(databaseProvider),
    ref.watch(settingsRepositoryProvider),
    ref.watch(clockProvider),
  ),
);

final replyServiceProvider = Provider<ReplyService>(
  (ref) => ReplyService(
    repo: ref.watch(assistantRepositoryProvider),
    platform: ref.watch(assistantPlatformProvider),
    drafter: ref.watch(replyDrafterProvider),
    clock: ref.watch(clockProvider),
  ),
);

final ingestionServiceProvider = Provider<IngestionService>((ref) {
  final s = IngestionService(
    repo: ref.watch(assistantRepositoryProvider),
    platform: ref.watch(assistantPlatformProvider),
    replies: ref.watch(replyServiceProvider),
    clock: ref.watch(clockProvider),
  );
  ref.onDispose(s.stop);
  return s;
});

final assistantControllerProvider = Provider<AssistantController>(
  (ref) => AssistantController(
    repo: ref.watch(assistantRepositoryProvider),
    platform: ref.watch(assistantPlatformProvider),
  ),
);

final briefingServiceProvider = Provider<BriefingService>((ref) {
  final db = ref.watch(databaseProvider);
  return BriefingService(
    repo: ref.watch(assistantRepositoryProvider),
    platform: ref.watch(assistantPlatformProvider),
    clock: ref.watch(clockProvider),
    calendar: ref.watch(calendarReaderProvider),
    sources: BriefingSources(
      profile: () => ref.read(profileRepositoryProvider).get(),
      stepsToday: (today) async {
        final m = await ref
            .read(healthRepositoryProvider)
            .watchResolvedSteps(today, today)
            .first;
        return m[today]?.steps;
      },
      foodToday: (today) async {
        final rows = await ref.read(foodLogRepositoryProvider).day(today);
        var kcal = 0.0, protein = 0.0;
        for (final r in rows) {
          kcal += r.calories;
          protein += r.proteinG;
        }
        return (kcal, protein);
      },
      waterTodayMl: (today) async {
        final rows = await WaterRepository(
          db,
          ref.read(clockProvider),
        ).day(today);
        return rows.fold<int>(0, (a, r) => a + r.amountMl);
      },
      habitsToday: (today) async {
        final board = await ref.read(habitBoardLoaderProvider).load(today);
        return (board.dueToday.length, board.remainingToday);
      },
    ),
  );
});

final assistantSettingsProvider = StreamProvider<AssistantSettings>(
  (ref) => ref.watch(assistantRepositoryProvider).watchSettings(),
);

final messagingAppsProvider = StreamProvider<List<MessagingAppSetting>>(
  (ref) => ref.watch(assistantRepositoryProvider).watchApps(),
);

final contactRulesProvider = StreamProvider<List<MessagingContactRule>>(
  (ref) => ref.watch(assistantRepositoryProvider).watchContacts(),
);

final openDraftsProvider = StreamProvider<List<ReplyDraft>>(
  (ref) => ref.watch(assistantRepositoryProvider).watchOpenDrafts(),
);

final decidedDraftsProvider = StreamProvider<List<ReplyDraft>>(
  (ref) => ref.watch(assistantRepositoryProvider).watchDecidedDrafts(),
);

final recentCapturedProvider = StreamProvider<List<CapturedNotification>>(
  (ref) => ref.watch(assistantRepositoryProvider).watchRecentCaptured(),
);

final auditProvider = StreamProvider<List<AutomationAuditData>>(
  (ref) => ref.watch(assistantRepositoryProvider).watchAudit(),
);

/// Device capability snapshot. Invalidate to refresh (e.g. on resume).
class AssistantDeviceStatus {
  const AssistantDeviceStatus({
    required this.listenerEnabled,
    required this.listenerConnected,
    required this.serviceRunning,
    required this.batteryUnrestricted,
    required this.notificationsEnabled,
    required this.exactAlarms,
  });
  final bool listenerEnabled;
  final bool listenerConnected;
  final bool serviceRunning;
  final bool batteryUnrestricted;
  final bool? notificationsEnabled;
  final bool? exactAlarms;
}

final assistantDeviceStatusProvider = FutureProvider<AssistantDeviceStatus>((
  ref,
) async {
  final p = ref.watch(assistantPlatformProvider);
  return AssistantDeviceStatus(
    listenerEnabled: await p.isListenerEnabled(),
    listenerConnected: await p.isListenerConnected(),
    serviceRunning: await p.isAssistantServiceRunning(),
    batteryUnrestricted: await p.isIgnoringBatteryOptimizations(),
    notificationsEnabled: await p.areNotificationsEnabled(),
    exactAlarms: await p.canScheduleExactAlarms(),
  );
});

final briefingLinesProvider = FutureProvider<List<BriefingLine>>(
  (ref) => ref.watch(briefingServiceProvider).build(),
);

final launchableAppsProvider = FutureProvider<List<LaunchableApp>>(
  (ref) => ref.watch(assistantPlatformProvider).listLaunchableApps(),
);

/// Text shared into the app, waiting for the user to pick an action.
class PendingShareNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? text) => state = text;
}

final pendingShareProvider = NotifierProvider<PendingShareNotifier, String?>(
  PendingShareNotifier.new,
);
