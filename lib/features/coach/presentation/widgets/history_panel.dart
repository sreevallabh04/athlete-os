import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/util/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../data/db/database.dart';
import '../../agent/coach_controller.dart';
import '../../data/coach_repository.dart';

/// Slides the session history in from the left edge (frosted side sheet).
Future<void> showConversationHistory(BuildContext context) {
  Haptics.light();
  final reduced = AppMotion.reduced(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close history',
    barrierColor: Colors.black.withValues(alpha: 0.5),
    transitionDuration: reduced
        ? Duration.zero
        : const Duration(milliseconds: 420),
    pageBuilder: (context, _, _) => const _HistoryPanel(),
    transitionBuilder: (context, anim, _, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: SpringCurve(AppMotion.gentle),
        reverseCurve: AppMotion.emphasizedAccelerate,
      );
      return SlideTransition(
        position: Tween(
          begin: const Offset(-1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      );
    },
  );
}

class _HistoryPanel extends ConsumerWidget {
  const _HistoryPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    final convs = ref.watch(conversationsProvider);
    final current = ref.watch(
      coachControllerProvider.select((s) => s.conversationId),
    );
    final controller = ref.read(coachControllerProvider.notifier);
    final now = ref.watch(clockProvider).now();
    final width = (MediaQuery.sizeOf(context).width * 0.86).clamp(0.0, 420.0);
    const radius = BorderRadius.horizontal(right: Radius.circular(AppRadii.xl));
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: width,
        height: double.infinity,
        child: Material(
          type: MaterialType.transparency,
          child: ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  color: hud.glassFillStrong,
                  border: Border(
                    right: BorderSide(
                      color: hud.jarvis.withValues(alpha: 0.35),
                    ),
                  ),
                ),
                child: SafeArea(
                  right: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'SESSION ARCHIVE',
                                    style: hud.label(
                                      size: 11,
                                      color: hud.jarvisInk,
                                    ),
                                  ),
                                  Text('History', style: t.headlineSmall),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Close',
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () => Navigator.pop(context),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                        child: HudButton.secondary(
                          label: 'New session',
                          icon: Icons.add_rounded,
                          expand: true,
                          onPressed: () {
                            controller.newConversation();
                            Navigator.pop(context);
                          },
                        ),
                      ),
                      Expanded(
                        child: convs.when(
                          loading: () => const Padding(
                            padding: EdgeInsets.all(20),
                            child: ScanlineLoader(lines: 4),
                          ),
                          error: (e, _) => const ErrorState(
                            message: 'Could not load sessions.',
                          ),
                          data: (list) => list.isEmpty
                              ? const EmptyState(
                                  icon: Icons.forum_outlined,
                                  title: 'No sessions yet',
                                  message:
                                      'Every conversation with JARVIS is '
                                      'kept here, on this phone.',
                                  compact: true,
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    12,
                                    24,
                                  ),
                                  itemCount: list.length,
                                  itemBuilder: (context, i) => Entrance(
                                    delay: Duration(
                                      milliseconds: 40 * i.clamp(0, 8),
                                    ),
                                    child: _SessionTile(
                                      conversation: list[i],
                                      selected: list[i].id == current,
                                      now: now,
                                      onOpen: () {
                                        controller.openConversation(list[i].id);
                                        Navigator.pop(context);
                                      },
                                      onDelete: () async {
                                        await ref
                                            .read(coachRepositoryProvider)
                                            .deleteConversation(list[i].id);
                                        if (current == list[i].id) {
                                          controller.newConversation();
                                        }
                                      },
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                        child: Text(
                          'STORED ON THIS PHONE · SWIPE LEFT TO DELETE',
                          style: hud.mono(size: 9.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.conversation,
    required this.selected,
    required this.now,
    required this.onOpen,
    required this.onDelete,
  });

  final AiConversation conversation;
  final bool selected;
  final DateTime now;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    final title = conversation.title ?? 'Session';
    final briefing = title == 'Morning briefing' || title == 'Evening review';
    return Dismissible(
      key: ValueKey(conversation.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) {
        Haptics.heavy();
        onDelete();
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.md),
          color: AppColors.danger.withValues(alpha: 0.18),
        ),
        child: const Icon(Icons.delete_outline, color: AppColors.danger),
      ),
      child: Semantics(
        button: true,
        selected: selected,
        label: title,
        child: PressableScale(
          onTap: onOpen,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.md),
              color: selected
                  ? hud.jarvis.withValues(alpha: 0.10)
                  : Colors.transparent,
              border: Border.all(
                color: selected
                    ? hud.jarvis.withValues(alpha: 0.5)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  // Same icons as the quick commands: sunrise for the
                  // morning briefing, moon for the evening review.
                  !briefing
                      ? Icons.chat_bubble_outline_rounded
                      : title.toLowerCase().contains('evening')
                      ? Icons.nights_stay_outlined
                      : Icons.wb_twilight_rounded,
                  size: 18,
                  color: selected ? hud.jarvis : hud.textMuted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodyLarge,
                      ),
                      Text(
                        Fmt.ago(conversation.updatedAt, now).toUpperCase(),
                        style: hud.mono(size: 10),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Delete',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: hud.textMuted,
                  ),
                  onPressed: () {
                    Haptics.heavy();
                    onDelete();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
