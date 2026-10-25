import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/assistant/application/providers.dart';
import 'package:athlete_os/features/assistant/application/reply_drafter.dart';
import 'package:athlete_os/features/assistant/application/reply_service.dart';
import 'package:athlete_os/features/assistant/data/assistant_platform.dart';
import 'package:athlete_os/features/assistant/data/fake_assistant_platform.dart';
import 'package:athlete_os/features/assistant/domain/assistant_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../helpers/test_app.dart';

final testNow = DateTime(2026, 10, 25, 9);

const whatsapp = 'com.whatsapp';
const sms = 'com.google.android.apps.messaging';

/// Drafter returning a fixed result and recording requests.
class FakeDrafter implements ReplyDrafter {
  FakeDrafter([DraftResult? result])
    : result =
          result ??
          const DraftResult(
            text: 'Got it, thanks!',
            category: ReplyCategory.acknowledgement,
            confidence: 0.95,
          );

  DraftResult result;
  final List<DraftRequest> requests = [];

  @override
  bool get isConfigured => true;

  @override
  Future<DraftResult> draft(DraftRequest request) async {
    requests.add(request);
    return result;
  }
}

/// Overrides for assistant tests: in-memory DB, fixed clock, fake platform,
/// optional drafter, zero retry delay and a recording clipboard.
List<Override> assistantOverrides(
  AppDatabase db,
  FakeAssistantPlatform platform, {
  ReplyDrafter? drafter,
  List<String>? clipboard,
  DateTime? now,
}) => [
  ...testOverrides(db, now: now ?? testNow),
  assistantPlatformProvider.overrideWithValue(platform),
  if (drafter != null) replyDrafterProvider.overrideWithValue(drafter),
  replyServiceProvider.overrideWith(
    (ref) => ReplyService(
      repo: ref.watch(assistantRepositoryProvider),
      platform: ref.watch(assistantPlatformProvider),
      drafter: ref.watch(replyDrafterProvider),
      clock: ref.watch(clockProvider),
      retryDelay: Duration.zero,
      copyToClipboard: (t) async => clipboard?.add(t),
    ),
  ),
];

ProviderContainer assistantContainer(
  AppDatabase db,
  FakeAssistantPlatform platform, {
  ReplyDrafter? drafter,
  List<String>? clipboard,
  DateTime? now,
}) => ProviderContainer(
  overrides: assistantOverrides(
    db,
    platform,
    drafter: drafter,
    clipboard: clipboard,
    now: now,
  ),
);

CapturedEvent ev({
  String pkg = whatsapp,
  String conv = 'shortcut-mom',
  String text = 'Are we still on for dinner tonight?',
  String? title = 'Mom',
  String? sender = 'Mom',
  bool group = false,
  String identity = 'high',
  bool reply = true,
  DateTime? at,
  String key = '0|com.whatsapp|1|null|10123',
}) => CapturedEvent(
  notificationKey: key,
  packageName: pkg,
  conversationKey: conv,
  identityConfidence: identity,
  title: title,
  sender: sender,
  isGroup: group,
  text: text,
  postedAt: (at ?? testNow.subtract(const Duration(minutes: 1))).toUtc(),
  hasReplyAction: reply,
);

/// Enables [pkg] with [mode] and sets the global mode.
Future<void> enableApp(
  ProviderContainer c,
  String pkg, {
  AssistantMode mode = AssistantMode.draft,
  AssistantMode global = AssistantMode.draft,
  bool allowAi = false,
  String label = 'App',
}) async {
  final ctl = c.read(assistantControllerProvider);
  await ctl.setMode(global);
  await ctl.updateApp(
    pkg,
    appLabel: label,
    enabled: true,
    mode: mode,
    allowAi: allowAi,
  );
}

/// Approves a conversation for restricted auto-reply.
Future<void> approveContact(
  ProviderContainer c,
  String pkg,
  String conv, {
  int maxAuto = 2,
  bool group = false,
  String identity = 'high',
}) async {
  final repo = c.read(assistantRepositoryProvider);
  final rule = await repo.ensureContact(
    packageName: pkg,
    conversationKey: conv,
    displayName: 'Contact',
    isGroup: group,
    identityConfidence: identity,
  );
  await repo.updateContact(
    rule.id,
    rule: 'approved',
    maxAutoRepliesPerDay: maxAuto,
  );
}
