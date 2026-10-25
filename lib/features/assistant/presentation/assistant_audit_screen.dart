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
    final muted = t.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );

    return AppPage(
      title: 'Automation log',
      subtitle:
          '"Handed off" means the reply was given to the app\'s own reply '
          'action. Apps do not confirm delivery.',
      children: [
        const SectionHeader('Replies'),
        replies.when(
          loading: () => const LoadingState(),
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
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final d in list)
                        ListTile(
                          title: Text(
                            d.draftText.isEmpty
                                ? '(text deleted by retention)'
                                : d.draftText,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              appLabelFor(d.packageName, labels),
                              if (d.sendPolicy != null) d.sendPolicy!,
                              Fmt.ago(
                                d.sentAt ?? d.decidedAt ?? d.createdAt,
                                now,
                              ),
                              if (d.deliveryDetail != null) d.deliveryDetail!,
                            ].join(' · '),
                          ),
                          trailing: StatusPill(
                            DraftStatus.label(d.status),
                            color: _statusColor(d.status),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
        const SectionHeader(
          'Timeline',
          subtitle: 'Metadata only — never message text.',
        ),
        audit.when(
          loading: () => const LoadingState(),
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
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final a in rows)
                        ListTile(
                          dense: true,
                          leading: Icon(_icon(a.action)),
                          title: Text(
                            [
                              a.action.replaceAll('_', ' '),
                              if (a.packageName != null)
                                appLabelFor(a.packageName!, labels),
                            ].join(' · '),
                          ),
                          subtitle: Text(
                            [
                              Fmt.ago(a.createdAt, now),
                              if (a.detail != null && a.detail!.isNotEmpty)
                                a.detail!,
                            ].join(' · '),
                            style: muted,
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
