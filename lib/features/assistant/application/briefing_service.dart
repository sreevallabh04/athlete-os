import 'dart:async';

import '../../../core/contracts/calendar_reader.dart';
import '../../../core/time/clock.dart';
import '../../../data/db/database.dart';
import '../domain/assistant_models.dart';
import '../domain/assistant_settings.dart';
import '../domain/briefing_builder.dart';
import '../domain/safe_log.dart';
import '../data/assistant_platform.dart';
import '../data/assistant_repository.dart';

/// Sources the briefing reads. Each returns null when unknown; failures are
/// treated as unknown (never as zero).
class BriefingSources {
  const BriefingSources({
    required this.profile,
    required this.stepsToday,
    required this.foodToday,
    required this.waterTodayMl,
    required this.habitsToday,
  });

  final Future<UserProfile?> Function() profile;
  final Future<int?> Function(String today) stepsToday;

  /// (calories, protein) logged today.
  final Future<(double, double)?> Function(String today) foodToday;
  final Future<int?> Function(String today) waterTodayMl;

  /// (due, remaining)
  final Future<(int, int)?> Function(String today) habitsToday;
}

class BriefingService {
  BriefingService({
    required this.repo,
    required this.platform,
    required this.clock,
    required this.calendar,
    required this.sources,
    this.builder = const BriefingBuilder(),
  });

  final AssistantRepository repo;
  final AssistantPlatform platform;
  final Clock clock;
  final CalendarReader calendar;
  final BriefingSources sources;
  final BriefingBuilder builder;

  static const unansweredAfter = Duration(hours: 2);

  Future<T?> _safe<T>(Future<T?> Function() f) async {
    try {
      return await f();
    } catch (e) {
      safeLog('briefing_source_failed', {'error': errorCode(e)});
      return null;
    }
  }

  Future<BriefingInputs> gather() async {
    final now = clock.now();
    final today = LocalDates.key(now);
    final (_, endOfDay) = LocalDates.bounds(today);
    // Sequential on purpose (one DB connection); each is failure-tolerant.
    final profile = await _safe(sources.profile);
    final steps = await _safe(() => sources.stepsToday(today));
    final food = await _safe(() => sources.foodToday(today));
    final water = await _safe(() => sources.waterTodayMl(today));
    final habits = await _safe(() => sources.habitsToday(today));
    // Network-backed: bounded so a slow calendar never blocks the briefing.
    final cal = await _safe(
      () => calendar
          .eventsBetween(now, endOfDay)
          .timeout(const Duration(seconds: 5)),
    );
    final drafts = await _safe(repo.openDraftCount);
    final unanswered = await _safe(() => possiblyUnanswered(now));
    return BriefingInputs(
      now: now,
      steps: steps,
      stepGoal: profile?.stepGoal,
      caloriesConsumed: food?.$1,
      calorieTarget: profile?.calorieTarget.toDouble(),
      proteinConsumed: food?.$2,
      proteinTarget: profile?.proteinTargetG,
      waterMl: water,
      waterGoalMl: profile?.waterGoalMl,
      calendar: cal,
      pendingDrafts: drafts ?? 0,
      unanswered: unanswered ?? const [],
      habitsDue: habits?.$1,
      habitsRemaining: habits?.$2,
    );
  }

  Future<List<BriefingLine>> build() async => builder.build(await gather());

  /// Heuristic: conversations whose latest captured message is older than
  /// [unansweredAfter], was not replied to/dismissed, and has no reply
  /// handed off after it.
  Future<List<UnansweredConversation>> possiblyUnanswered(DateTime now) async {
    final captured = await repo.watchRecentCaptured().first;
    final drafts = await repo.allDrafts();
    final apps = {for (final a in await repo.apps()) a.packageName: a.appLabel};
    final latest = <String, CapturedNotification>{};
    for (final c in captured) {
      final k = '${c.packageName}|${c.conversationKey}';
      final cur = latest[k];
      if (cur == null || c.postedAt.isAfter(cur.postedAt)) latest[k] = c;
    }
    final out = <UnansweredConversation>[];
    for (final c in latest.values) {
      if (c.isGroup) continue;
      if (c.status != CaptureStatus.fresh &&
          c.status != CaptureStatus.drafted) {
        continue;
      }
      if (now.toUtc().difference(c.postedAt.toUtc()) < unansweredAfter) {
        continue;
      }
      final replied = drafts.any(
        (d) =>
            d.packageName == c.packageName &&
            d.conversationKey == c.conversationKey &&
            d.status == DraftStatus.handedOff &&
            (d.sentAt?.isAfter(c.postedAt) ?? false),
      );
      if (replied) continue;
      out.add(
        UnansweredConversation(
          title: c.conversationTitle ?? c.sender ?? 'Unknown',
          appLabel: apps[c.packageName] ?? c.packageName,
          lastAt: c.postedAt,
        ),
      );
    }
    out.sort((a, b) => b.lastAt.compareTo(a.lastAt));
    return out;
  }

  /// Posts the morning briefing / evening review when its time has passed
  /// today and it was not posted yet. Only runs while the app (or Assistant
  /// mode) keeps the Dart side alive — see docs/MESSAGING_ASSISTANT.md.
  Future<void> maybePostScheduled() async {
    final settings = await repo.settings();
    if (settings.killSwitch) return;
    final b = settings.briefing;
    final now = clock.now();
    final local = now.isUtc ? now.toLocal() : now;
    final minute = local.hour * 60 + local.minute;
    final today = LocalDates.key(local);
    Future<void> check({
      required bool enabled,
      required int at,
      required String key,
      required String title,
      required String publicTitle,
      required int id,
    }) async {
      if (!enabled || minute < at || minute > at + 180) return;
      final last = await repo.getSetting<String>(key);
      if (last == today) return;
      final lines = await build();
      final body = builder.notificationBody(lines);
      final ok = await platform.postNotification(
        id,
        title,
        body.isEmpty ? 'All caught up.' : body,
        // Contact names, health numbers and schedule: never on the lock
        // screen, only the generic public version.
        visibility: LockScreenVisibility.private,
        publicTitle: publicTitle,
        publicBody: AssistantLockScreenCopy.body,
      );
      if (ok) await repo.setSetting(key, today);
    }

    await check(
      enabled: b.morningEnabled,
      at: b.morningMinutes,
      key: AssistantKeys.lastMorningBriefing,
      title: 'Good morning — your briefing',
      publicTitle: AssistantLockScreenCopy.briefingTitle,
      id: 7201,
    );
    await check(
      enabled: b.eveningEnabled,
      at: b.eveningMinutes,
      key: AssistantKeys.lastEveningReview,
      title: 'Evening review',
      publicTitle: AssistantLockScreenCopy.reviewTitle,
      id: 7202,
    );
  }
}
