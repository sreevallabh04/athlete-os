import 'package:collection/collection.dart' show mergeSort;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/providers.dart';
import '../application/reply_drafter.dart';
import '../application/reply_service.dart' show aiExcludedFlags;
import '../domain/assistant_models.dart';
import '../domain/briefing_builder.dart';
import '../domain/priority.dart';
import '../domain/sensitivity_classifier.dart';
import 'widgets/assistant_widgets.dart';
import 'widgets/draft_card.dart';

class AssistantScreen extends ConsumerWidget {
  const AssistantScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final share = ref.watch(pendingShareProvider);
    final drafts = ref.watch(openDraftsProvider);
    final captured = ref.watch(recentCapturedProvider);
    final apps = ref.watch(messagingAppsProvider).value ?? const [];
    final labels = {for (final a in apps) a.packageName: a.appLabel};
    final now = ref.watch(clockProvider).now();

    return AppPage(
      title: 'Assistant',
      eyebrow: 'COMMS · TRIAGE',
      subtitle: 'Your personal assistant phone — you stay in control.',
      onRefresh: () async {
        await ref.read(ingestionServiceProvider).drainAndIngest();
        ref.invalidate(assistantDeviceStatusProvider);
        ref.invalidate(briefingLinesProvider);
      },
      actions: [
        IconButton(
          tooltip: 'Automation log',
          icon: const Icon(Icons.history),
          onPressed: () => context.push(AppPaths.assistantAudit),
        ),
        IconButton(
          tooltip: 'Assistant settings',
          icon: const Icon(Icons.tune),
          onPressed: () => context.push(AppPaths.assistantSettings),
        ),
      ],
      children: [
        if (share != null) ...[
          _SharedTextCard(text: share),
          const SizedBox(height: AppSpacing.md),
        ],
        const KillSwitchCard(),
        const SectionHeader(
          'Needs your reply',
          subtitle: 'Nothing is sent until you tap Send.',
        ),
        drafts.when(
          loading: () => const ScanlineLoader(height: 140, lines: 0),
          error: (e, _) => const ErrorState(message: 'Could not load drafts.'),
          data: (list) {
            if (list.isEmpty) {
              return const AppCard(
                child: EmptyState(
                  compact: true,
                  icon: Icons.mark_chat_read_outlined,
                  title: 'Inbox zero',
                  message:
                      'Drafts appear here for messages from apps you enabled.',
                ),
              );
            }
            final all = captured.value ?? const <CapturedNotification>[];
            List<CapturedNotification> msgsFor(ReplyDraft d) => all
                .where(
                  (c) =>
                      c.packageName == d.packageName &&
                      c.conversationKey == d.conversationKey,
                )
                .take(5)
                .toList()
                .reversed
                .toList();
            int score(ReplyDraft d) {
              final m = msgsFor(d);
              final risk = d.risk == 'high' ? 10 : 0;
              if (m.isEmpty) return risk;
              final last = m.last;
              return risk +
                  priorityOf(
                    text: last.body,
                    flags: SensitivityResult.parseCsv(last.sensitivityFlags),
                    postedAt: last.postedAt,
                    now: now,
                  ).score;
            }

            // Triage: highest priority first (stable for ties).
            final scores = {for (final d in list) d.id: score(d)};
            final sorted = [...list];
            mergeSort(
              sorted,
              compare: (a, b) => scores[b.id]!.compareTo(scores[a.id]!),
            );
            return Column(
              children: spaced([
                for (final d in sorted)
                  DraftInboxTile(
                    key: ValueKey('draft-${d.id}'),
                    primary: d == sorted.first,
                    draft: d,
                    appLabel: appLabelFor(d.packageName, labels),
                    messages: msgsFor(d),
                  ),
              ]),
            );
          },
        ),
        ..._priorities(context, captured.value ?? const [], labels, now),
        const SectionHeader('System status'),
        const _StatusCard(),
        const SectionHeader('Briefing'),
        const _BriefingCard(),
        const SectionHeader('Recent messages'),
        captured.when(
          loading: () => const ScanlineLoader(lines: 3),
          error: (e, _) =>
              const ErrorState(message: 'Could not load messages.'),
          data: (list) => _RecentConversations(rows: list, labels: labels),
        ),
        const SectionHeader('Systems'),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _NavRow(
                icon: Icons.tune,
                title: 'Assistant settings',
                subtitle: 'Apps, modes, contacts, tone, limits',
                onTap: () => context.push(AppPaths.assistantSettings),
              ),
              _NavRow(
                icon: Icons.history,
                title: 'Automation log',
                subtitle: 'Every decision, without message text',
                onTap: () => context.push(AppPaths.assistantAudit),
              ),
              _NavRow(
                icon: Icons.verified_user_outlined,
                title: 'Permissions & capabilities',
                subtitle: 'Live status matrix',
                onTap: () => context.push(AppPaths.capabilities),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _priorities(
    BuildContext context,
    List<CapturedNotification> rows,
    Map<String, String> labels,
    DateTime now,
  ) {
    final hints = <(CapturedNotification, PriorityHint)>[];
    for (final c in rows) {
      if (c.status == CaptureStatus.replied) continue;
      final h = priorityOf(
        text: c.body,
        flags: SensitivityResult.parseCsv(c.sensitivityFlags),
        postedAt: c.postedAt,
        now: now,
      );
      if (h.isPriority) hints.add((c, h));
    }
    if (hints.isEmpty) return const [];
    hints.sort((a, b) => b.$2.score.compareTo(a.$2.score));
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    return [
      const SectionHeader(
        'Priorities',
        subtitle: 'Heuristic: urgent words, questions, time mentions',
        accent: AppColors.warning,
      ),
      AppCard(
        accent: AppColors.warning,
        child: Column(
          children: spaced(gap: AppSpacing.md, [
            for (final (c, h) in hints.take(5))
              Row(
                children: [
                  InitialsAvatar(
                    name: c.conversationTitle ?? c.sender ?? '?',
                    seed: c.packageName,
                    size: 34,
                    halo: h.score >= 4 ? AppColors.danger : AppColors.warning,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${c.conversationTitle ?? c.sender ?? 'Unknown'} · '
                          '${appLabelFor(c.packageName, labels)}',
                          style: t.titleSmall,
                        ),
                        Text(
                          '${h.reasons.join(' · ')} · '
                          '${Fmt.ago(c.postedAt, now)}',
                          style: t.bodySmall?.copyWith(color: hud.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
          ]),
        ),
      ),
    ];
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: GlowIcon(icon, size: 18, framed: true),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: onTap,
  );
}

/// Live status: notification access, enabled apps, global mode and the
/// keep-alive service, each with a glowing LED pill.
class _StatusCard extends ConsumerWidget {
  const _StatusCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(assistantDeviceStatusProvider).value;
    final settings = ref.watch(assistantSettingsProvider).value;
    final apps = ref.watch(messagingAppsProvider).value ?? const [];
    final enabledApps = apps.where((a) => a.enabled).length;
    final t = Theme.of(context).textTheme;
    final hud = HudTheme.of(context);
    final listenerOn = status?.listenerEnabled ?? false;
    final serviceOn = status?.serviceRunning ?? false;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'LIVE · ON THIS PHONE',
                  style: hud.label(size: 11.5),
                ),
              ),
              StatusPill(
                settings?.mode.label ?? '…',
                color: AppColors.brand,
                icon: Icons.auto_mode,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _row(
            context,
            icon: Icons.notifications_active_outlined,
            label: 'Notification access',
            on: listenerOn,
            onText: status?.listenerConnected ?? false
                ? 'On · connected'
                : 'On',
            offText: 'Off',
            action: listenerOn ? null : 'Set up',
            onAction: () => requestNotificationAccess(context, ref),
          ),
          _row(
            context,
            icon: Icons.apps,
            label: 'Apps enabled',
            on: enabledApps > 0,
            onText: '$enabledApps',
            offText: 'None',
            action: enabledApps > 0 ? null : 'Choose',
            onAction: () => context.push(AppPaths.assistantSettings),
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Icon(Icons.bolt_outlined, size: 20, color: hud.textMuted),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Assistant mode (keep running)', style: t.bodyLarge),
                    Text(
                      serviceOn
                          ? 'Running with a persistent notification'
                          : 'Off — processing happens while the app is open',
                      style: t.bodySmall?.copyWith(color: hud.textMuted),
                    ),
                  ],
                ),
              ),
              HudToggle(
                value: serviceOn,
                semanticLabel: 'Assistant mode (keep running)',
                onChanged: (settings?.killSwitch ?? false)
                    ? null
                    : (v) async {
                        await ref
                            .read(assistantControllerProvider)
                            .setServiceEnabled(v);
                        ref.invalidate(assistantDeviceStatusProvider);
                      },
              ),
            ],
          ),
          if (status != null && !status.batteryUnrestricted) ...[
            const SizedBox(height: AppSpacing.sm),
            NoticeBanner(
              message:
                  'Battery optimisation may stop the assistant on ColorOS.',
              color: AppColors.warning,
              icon: Icons.battery_alert,
              actionLabel: 'Fix',
              onAction: () => context.push(AppPaths.capabilities),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool on,
    required String onText,
    required String offText,
    String? action,
    VoidCallback? onAction,
  }) {
    final hud = HudTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 20, color: hud.textMuted),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyLarge),
          ),
          StatusPill(
            on ? onText : offText,
            color: on ? AppColors.success : AppColors.warning,
          ),
          if (action != null)
            HudButton.ghost(label: action, compact: true, onPressed: onAction),
        ],
      ),
    );
  }
}

class _BriefingCard extends ConsumerWidget {
  const _BriefingCard();

  static IconData _icon(BriefingKind k) => switch (k) {
    BriefingKind.steps => Icons.directions_walk,
    BriefingKind.calories => Icons.local_fire_department_outlined,
    BriefingKind.protein => Icons.egg_outlined,
    BriefingKind.water => Icons.water_drop_outlined,
    BriefingKind.calendar => Icons.event_outlined,
    BriefingKind.drafts => Icons.mark_chat_unread_outlined,
    BriefingKind.unanswered => Icons.forum_outlined,
    BriefingKind.habits => Icons.check_circle_outline,
  };

  static Color _color(BriefingKind k) => switch (k) {
    BriefingKind.steps => AppColors.steps,
    BriefingKind.calories => AppColors.calories,
    BriefingKind.protein => AppColors.protein,
    BriefingKind.water => AppColors.water,
    BriefingKind.calendar => AppColors.cyan,
    BriefingKind.drafts => AppColors.gold,
    BriefingKind.unanswered => AppColors.warning,
    BriefingKind.habits => AppColors.habit,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(briefingLinesProvider);
    final hud = HudTheme.of(context);
    final small = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: hud.textMuted);
    return AppCard(
      child: lines.when(
        loading: () => const ScanlineLoader(lines: 3),
        error: (e, _) => const Text('Briefing unavailable right now.'),
        data: (list) => list.isEmpty
            ? const Text('Nothing to report yet.')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final l in list)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GlowIcon(
                            l.done ? Icons.check_circle : _icon(l.kind),
                            size: 18,
                            color: l.done ? AppColors.success : _color(l.kind),
                            glow: l.done ? 1 : 0.4,
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(l.text),
                                if (l.note != null) Text(l.note!, style: small),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _RecentConversations extends ConsumerWidget {
  const _RecentConversations({required this.rows, required this.labels});
  final List<CapturedNotification> rows;
  final Map<String, String> labels;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (rows.isEmpty) {
      return const AppCard(
        child: EmptyState(
          compact: true,
          icon: Icons.inbox_outlined,
          title: 'No captured messages',
          message:
              'Enable notification access and at least one app in settings.',
        ),
      );
    }
    final now = ref.watch(clockProvider).now();
    final groups = <String, List<CapturedNotification>>{};
    for (final r in rows) {
      (groups['${r.packageName}|${r.conversationKey}'] ??= []).add(r);
    }
    return Column(
      children: spaced([
        for (final g in groups.values.take(20))
          _ConversationCard(
            rows: g,
            appLabel: appLabelFor(g.first.packageName, labels),
            now: now,
          ),
      ]),
    );
  }
}

class _ConversationCard extends ConsumerStatefulWidget {
  const _ConversationCard({
    required this.rows,
    required this.appLabel,
    required this.now,
  });
  final List<CapturedNotification> rows;
  final String appLabel;
  final DateTime now;

  @override
  ConsumerState<_ConversationCard> createState() => _ConversationCardState();
}

class _ConversationCardState extends ConsumerState<_ConversationCard> {
  String? _summary;
  bool _busy = false;

  Future<void> _summarize() async {
    final latest = widget.rows.first;
    final repo = ref.read(assistantRepositoryProvider);
    final settings = await repo.settings();
    final app = await repo.app(latest.packageName);
    final summarizer = ref.read(conversationSummarizerProvider);
    final flags = SensitivityResult.parseCsv(latest.sensitivityFlags);
    final n = widget.rows.length;
    final local =
        '$n message${n == 1 ? '' : 's'}, latest '
        '${Fmt.ago(latest.postedAt, widget.now)}'
        '${flags.isEmpty ? '' : ' · ${flags.map((f) => f.label).join(', ')}'}';
    if (!mounted) return;
    if (settings.killSwitch) {
      setState(() => _summary = '$local\n(Emergency stop is on.)');
      return;
    }
    if (!settings.aiConsent || !(app?.allowAi ?? false)) {
      setState(
        () => _summary =
            '$local\n(AI summary needs AI consent and "Allow AI" for this '
            'app.)',
      );
      return;
    }
    if (!summarizer.isConfigured) {
      setState(() => _summary = '$local\n($aiUnavailableMessage)');
      return;
    }
    setState(() => _busy = true);
    try {
      final d =
          await repo.openDraftFor(latest.packageName, latest.conversationKey) ??
          await ref.read(replyServiceProvider).createManualDraft(latest.id);
      final request = d == null
          ? null
          : await ref
                .read(replyServiceProvider)
                .buildRequest(d, settings: settings, contact: null);
      final s = request == null ? null : await summarizer.summarize(request);
      if (mounted) setState(() => _summary = s ?? local);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final latest = widget.rows.first;
    final t = Theme.of(context).textTheme;
    final hud = HudTheme.of(context);
    final killed =
        ref.watch(assistantSettingsProvider).value?.killSwitch ?? false;
    final title = latest.conversationTitle ?? latest.sender ?? 'Unknown';
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InitialsAvatar(
                name: title,
                seed: latest.packageName,
                size: 34,
                badge: widget.appLabel,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.titleSmall),
                    Text(
                      '${widget.appLabel} · '
                              '${Fmt.ago(latest.postedAt, widget.now)}'
                          .toUpperCase(),
                      style: hud.mono(size: 10),
                    ),
                  ],
                ),
              ),
              if (latest.status == CaptureStatus.replied)
                const StatusPill('Replied', color: AppColors.success),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final r in widget.rows.take(3).toList().reversed)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                '${r.isGroup && r.sender != null ? '${r.sender}: ' : ''}'
                '${r.body}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (_summary != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: AppSpacing.xs),
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: hud.accent.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(AppRadii.sm),
              ),
              child: Text(
                _summary!,
                style: t.bodySmall?.copyWith(color: hud.textMuted),
              ),
            ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              HudButton.ghost(
                label: 'Summarize',
                icon: Icons.short_text_rounded,
                compact: true,
                loading: _busy,
                onPressed: _busy ? null : _summarize,
              ),
              HudButton.secondary(
                label: 'Draft',
                icon: Icons.edit_note_rounded,
                compact: true,
                onPressed: killed
                    ? null
                    : () => ref
                          .read(replyServiceProvider)
                          .createManualDraft(latest.id),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SharedTextCard extends ConsumerWidget {
  const _SharedTextCard({required this.text});
  final String text;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void clear() => ref.read(pendingShareProvider.notifier).set(null);
    return AppCard(
      accent: AppColors.info,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.share_outlined, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Shared with Athlete OS',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton(
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close),
                onPressed: clear,
              ),
            ],
          ),
          Text(text, maxLines: 6, overflow: TextOverflow.ellipsis),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              FilledButton.tonal(
                onPressed: () => _draftReply(context, ref, text),
                child: const Text('Draft a reply'),
              ),
              FilledButton.tonal(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  clear();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Text copied — paste it into the search.'),
                    ),
                  );
                  unawaited(
                    context.push(
                      Uri(
                        path: AppPaths.addFood,
                        queryParameters: {'q': text},
                      ).toString(),
                    ),
                  );
                },
                child: const Text('Log food from text'),
              ),
              FilledButton.tonal(
                onPressed: () {
                  clear();
                  context.go(
                    Uri(
                      path: AppPaths.coach,
                      queryParameters: {'prompt': text},
                    ).toString(),
                  );
                },
                child: const Text('Ask coach'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _draftReply(
    BuildContext context,
    WidgetRef ref,
    String shared,
  ) async {
    final settings = await ref.read(assistantRepositoryProvider).settings();
    final drafter = ref.read(replyDrafterProvider);
    var initial = '';
    String? note;
    final flags = const SensitivityClassifier().classify(text: shared).flags;
    if (settings.killSwitch) {
      note = 'Emergency stop is on — write your reply below.';
    } else if (flags.any(aiExcludedFlags.contains)) {
      note =
          'Not sent to AI: looks like a code, credentials or an emergency. '
          'Please reply yourself.';
    } else if (settings.aiConsent && drafter.isConfigured) {
      DraftResult r;
      try {
        r = await drafter.draft(
          DraftRequest(
            appLabel: 'Shared text',
            conversationTitle: null,
            isGroup: false,
            messages: [
              DraftMessage(text: shared, at: ref.read(clockProvider).now()),
            ],
            tone: settings.tone,
            maxLength: settings.limits.maxLength,
          ),
        );
      } catch (_) {
        r = const DraftResult.unavailable(
          'AI drafting failed — write your reply below.',
        );
      }
      if (r.available) {
        initial = r.text!;
      } else {
        note = r.needsHumanReason;
      }
    } else {
      note = drafter.isConfigured
          ? 'AI consent is off — write your reply below.'
          : aiUnavailableMessage;
    }
    if (!context.mounted) return;
    final controller = TextEditingController(text: initial);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Draft a reply'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(note),
              ),
            TextField(
              controller: controller,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(hintText: 'Your reply'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: controller.text));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Copy'),
          ),
        ],
      ),
    );
    controller.dispose();
  }
}
