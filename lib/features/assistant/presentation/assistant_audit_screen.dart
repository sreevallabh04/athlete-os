import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../application/providers.dart';
import '../domain/assistant_models.dart';
import 'widgets/assistant_widgets.dart';

/// Content-free automation timeline + replies with their delivery status.
class AssistantAuditScreen extends ConsumerWidget {
  const AssistantAuditScreen({super.key});

  static IconData _icon(String action) => switch (action) {
    AuditAction.capture => Icons.download_outlined,
    AuditAction.ignore => Icons.visibility_off_outlined,
    AuditAction.classify => Icons.rule,
    AuditAction.draft => Icons.edit_note,
    AuditAction.approve => Icons.thumb_up_alt_outlined,
    AuditAction.reject => Icons.thumb_down_alt_outlined,
    AuditAction.send => Icons.send_outlined,
    AuditAction.sendFailed => Icons.error_outline,
    AuditAction.killSwitch => Icons.stop_circle_outlined,
    _ => Icons.settings_outlined,
  };

  static Color _actionColor(String action, HudTheme hud) => switch (action) {
    AuditAction.send || AuditAction.approve => AppColors.success,
    AuditAction.sendFailed || AuditAction.killSwitch => AppColors.danger,
    AuditAction.reject => AppColors.warning,
    AuditAction.draft => hud.accent,
    _ => hud.textMuted,
  };

  static Color _statusColor(String s) => switch (s) {
    DraftStatus.handedOff => AppColors.success,
    DraftStatus.failed => AppColors.danger,
    DraftStatus.unsupported => AppColors.warning,
    DraftStatus.rejected => AppColors.info,
    _ => AppColors.info,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audit = ref.watch(auditProvider);
    final replies = ref.watch(decidedDraftsProvider);
    final apps = ref.watch(messagingAppsProvider).value ?? const [];
    final labels = {for (final a in apps) a.packageName: a.appLabel};
    final now = ref.watch(clockProvider).now();
    final t = Theme.of(context).textTheme;
    final hud = HudTheme.of(context);

    return AppPage(
      title: 'Automation log',
      eyebrow: 'AUDIT · CONTENT-FREE',
      subtitle:
          '"Handed off" means the reply was given to the app\'s own reply '
          'action. Apps do not confirm delivery.',
      children: [
        const SectionHeader('Replies'),
        replies.when(
          loading: () => const ScanlineLoader(lines: 3),
          error: (e, _) => const ErrorState(message: 'Could not load replies.'),
          data: (list) => list.isEmpty
              ? const AppCard(
                  child: EmptyState(
                    compact: true,
                    icon: Icons.outbox_outlined,
                    title: 'No replies yet',
                  ),
                )
              : AppCard(
                  child: Column(
                    children: spaced(gap: AppSpacing.md, [
                      for (final d in list)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InitialsAvatar(
                              name: appLabelFor(d.packageName, labels),
                              seed: d.packageName,
                              size: 32,
                            ),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    d.draftText.isEmpty
                                        ? '(text deleted by retention)'
                                        : d.draftText,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: t.bodyMedium,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    [
                                      appLabelFor(d.packageName, labels),
                                      if (d.sendPolicy != null) d.sendPolicy!,
                                      Fmt.ago(
                                        d.sentAt ?? d.decidedAt ?? d.createdAt,
                                        now,
                                      ),
                                      if (d.deliveryDetail != null)
                                        d.deliveryDetail!,
                                    ].join(' · '),
                                    style: hud.mono(size: 10),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            StatusPill(
                              DraftStatus.label(d.status),
                              color: _statusColor(d.status),
                            ),
                          ],
                        ),
                    ]),
                  ),
                ),
        ),
        const SectionHeader(
          'Timeline',
          subtitle: 'Metadata only — never message text.',
        ),
        audit.when(
          loading: () => const ScanlineLoader(lines: 4),
          error: (e, _) => const ErrorState(message: 'Could not load the log.'),
          data: (rows) => rows.isEmpty
              ? const AppCard(
                  child: EmptyState(
                    compact: true,
                    icon: Icons.history,
                    title: 'Nothing logged yet',
                  ),
                )
              : AppCard(
                  padding: const EdgeInsets.fromLTRB(12, 14, 14, 6),
                  child: Column(
                    children: [
                      for (var i = 0; i < rows.length; i++)
                        _TimelineRow(
                          icon: _icon(rows[i].action),
                          color: _actionColor(rows[i].action, hud),
                          title: [
                            rows[i].action.replaceAll('_', ' '),
                            if (rows[i].packageName != null)
                              appLabelFor(rows[i].packageName!, labels),
                          ].join(' · '),
                          subtitle: [
                            Fmt.ago(rows[i].createdAt, now),
                            if (rows[i].detail != null &&
                                rows[i].detail!.isNotEmpty)
                              rows[i].detail!,
                          ].join(' · '),
                          last: i == rows.length - 1,
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.last,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.12),
                    border: Border.all(color: color.withValues(alpha: 0.5)),
                  ),
                  child: Icon(icon, size: 14, color: color),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 1,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      color: hud.hairline.withValues(alpha: 0.2),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 3, bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: t.bodyMedium),
                  Text(subtitle, style: hud.mono(size: 10)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
