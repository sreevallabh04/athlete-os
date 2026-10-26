import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../agent/system_prompt.dart' show maxPromptMemories;
import '../data/coach_repository.dart';

const memoryCategories = ['preference', 'goal', 'routine', 'context'];

String _categoryLabel(String c) => switch (c) {
  'preference' => 'Preferences',
  'goal' => 'Goals',
  'routine' => 'Routines',
  'context' => 'Context',
  _ => c,
};

class AiMemoryScreen extends ConsumerWidget {
  const AiMemoryScreen({super.key});

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, {
    AiMemory? memory,
  }) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _MemoryDialog(memory: memory),
    );
    if (result == null) return;
    await ref
        .read(coachRepositoryProvider)
        .saveMemory(
          id: memory?.id,
          category: result.$1,
          content: result.$2,
          approved: true,
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memories = ref.watch(memoriesProvider);
    final repo = ref.read(coachRepositoryProvider);
    return AppPage(
      title: 'Coach memory',
      eyebrow: 'JARVIS · LONG-TERM MEMORY',
      subtitle:
          'Only approved memories are shared with the coach (most recent '
          '$maxPromptMemories).',
      // Same docked primary action as Journal, Mood and Planner.
      bottomAction: HudButton(
        expand: true,
        label: 'Add memory',
        icon: Icons.add,
        onPressed: () => _edit(context, ref),
      ),
      children: memories.when(
        loading: () => const [LoadingState()],
        error: (e, _) => const [ErrorState(message: 'Could not load memory.')],
        data: (list) {
          final pending = list.where((m) => !m.approved).toList();
          final approved = list.where((m) => m.approved).toList();
          return [
            if (pending.isNotEmpty) ...[
              const SectionHeader(
                'Suggested by the coach',
                subtitle: 'Not used until you approve',
              ),
              ...spaced([
                for (final m in pending)
                  AppCard(
                    accent: AppColors.warning,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const GlowIcon(
                              Icons.psychology_alt_outlined,
                              color: AppColors.warning,
                              size: 16,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              'PROPOSED · ${_categoryLabel(m.category)}'
                                  .toUpperCase(),
                              style: HudTheme.of(context)
                                  .label(size: 11, color: AppColors.warning),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          m.content,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Row(
                          children: [
                            HudButton(
                              label: 'Approve',
                              icon: Icons.check_rounded,
                              compact: true,
                              onPressed: () {
                                Haptics.success();
                                repo.setMemoryApproved(m.id, true);
                              },
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            HudButton.secondary(
                              label: 'Edit',
                              compact: true,
                              onPressed: () => _edit(context, ref, memory: m),
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            HudButton.ghost(
                              label: 'Reject',
                              compact: true,
                              onPressed: () {
                                Haptics.heavy();
                                repo.deleteMemory(m.id);
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ]),
            ],
            if (approved.isEmpty && pending.isEmpty)
              const EmptyState(
                icon: Icons.psychology_outlined,
                title: 'No memories yet',
                message:
                    'Add things the coach should always keep in mind, e.g. '
                    '"I train before work" or "I don\'t eat pork".',
              ),
            for (final c in memoryCategories)
              if (approved.any((m) => m.category == c)) ...[
                SectionHeader(_categoryLabel(c)),
                AppCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final m in approved.where((m) => m.category == c))
                        ListTile(
                          leading: GlowIcon(
                            m.origin == 'ai_suggested'
                                ? Icons.auto_awesome_rounded
                                : Icons.bookmark_outline_rounded,
                            size: 18,
                          ),
                          title: Text(m.content),
                          subtitle: m.origin == 'ai_suggested'
                              ? const Text('Suggested by coach · approved')
                              : null,
                          onTap: () => _edit(context, ref, memory: m),
                          trailing: IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => repo.deleteMemory(m.id),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
          ];
        },
      ),
    );
  }
}

class _MemoryDialog extends StatefulWidget {
  const _MemoryDialog({this.memory});
  final AiMemory? memory;

  @override
  State<_MemoryDialog> createState() => _MemoryDialogState();
}

class _MemoryDialogState extends State<_MemoryDialog> {
  late String _category = widget.memory?.category ?? 'preference';
  late final _content = TextEditingController(text: widget.memory?.content);

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.memory == null ? 'Add memory' : 'Edit memory'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: memoryCategories.contains(_category)
                ? _category
                : 'context',
            decoration: const InputDecoration(labelText: 'Category'),
            items: [
              for (final c in memoryCategories)
                DropdownMenuItem(value: c, child: Text(_categoryLabel(c))),
            ],
            onChanged: (v) => setState(() => _category = v ?? _category),
          ),
          TextField(
            controller: _content,
            maxLength: 300,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Memory'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final text = _content.text.trim();
            if (text.length < 3) return;
            Navigator.pop(context, (_category, text));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
