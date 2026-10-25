import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/settings_repository.dart';
import '../application/mood_journal_providers.dart';
import '../data/journal_repository.dart';
import '../domain/journal_text.dart';
import 'journal_editor_screen.dart';

class JournalScreen extends ConsumerWidget {
  const JournalScreen({super.key});

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export your journal?'),
        content: const Text(
          'This creates a plain-text copy of every entry and opens the share '
          'sheet. Only share it with apps or people you trust.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Export'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final entries = await ref.read(journalRepositoryProvider).all();
    final text = formatJournalExport([
      for (final e in entries)
        JournalExportEntry(
          localDate: e.localDate,
          body: e.body,
          gratitude: e.gratitude,
          prompt: e.prompt,
        ),
    ]);
    try {
      await SharePlus.instance.share(
        ShareParams(text: text, subject: 'My journal (Athlete OS)'),
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sharing isn\'t available right now.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(journalEntriesProvider);
    return AppPage(
      title: 'Journal',
      actions: [
        IconButton(
          tooltip: 'Export journal as text',
          icon: const Icon(Icons.ios_share),
          onPressed: () => _export(context, ref),
        ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'journal-write',
        onPressed: () => openJournalEditor(context),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Write'),
      ),
      children: [
        const SizedBox(height: AppSpacing.md),
        const _PrivacyNotice(),
        const SizedBox(height: AppSpacing.md),
        const AiJournalConsentCard(),
        const SectionHeader('Entries'),
        ...entries.when(
          loading: () => const [LoadingState()],
          error: (e, _) => [
            ErrorState(
              message: 'Your journal couldn\'t be loaded.',
              onRetry: () => ref.invalidate(journalEntriesProvider),
            ),
          ],
          data: (list) => list.isEmpty
              ? [
                  EmptyState(
                    icon: Icons.menu_book_outlined,
                    title: 'Nothing written yet',
                    message:
                        'A few lines are plenty. Prompts are there if you '
                        'want them.',
                    actionLabel: 'Write an entry',
                    onAction: () => openJournalEditor(context),
                  ),
                ]
              : spaced([
                  for (final e in list) _JournalEntryCard(entry: e),
                ], gap: AppSpacing.sm),
        ),
      ],
    );
  }
}

class _PrivacyNotice extends StatelessWidget {
  const _PrivacyNotice();
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_outline, color: AppColors.habit),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Private by default', style: t.titleSmall),
                const SizedBox(height: 2),
                Text(
                  'Stored only on this device; never sent to AI unless you '
                  'enable it below.',
                  style: t.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Toggle bound to `SettingKeys.aiJournalConsent` (default off).
class AiJournalConsentCard extends ConsumerWidget {
  const AiJournalConsentCard({super.key});

  Future<void> _set(BuildContext context, WidgetRef ref, bool on) async {
    if (on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Allow AI journal analysis?'),
          content: const Text(
            'If you turn this on, the AI coach may send the text of your '
            'journal entries to the AI provider configured in AI settings '
            'when you ask it to reflect on your journal. Entries are never '
            'sent automatically in the background.\n\n'
            'You can turn this off at any time; nothing is sent while it is '
            'off.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep off'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Allow'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await ref
        .read(settingsRepositoryProvider)
        .set(SettingKeys.aiJournalConsent, on);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(aiJournalConsentProvider).value ?? false;
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: SwitchListTile(
        secondary: const Icon(Icons.auto_awesome_outlined),
        title: const Text('AI journal analysis'),
        subtitle: Text(
          on
              ? 'On: the AI coach may read entries when you ask it to.'
              : 'Off: journal text never leaves this device.',
        ),
        value: on,
        onChanged: (v) => _set(context, ref, v),
      ),
    );
  }
}

class _JournalEntryCard extends StatelessWidget {
  const _JournalEntryCard({required this.entry});
  final JournalEntry entry;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final date = DateFormat('EEE, d MMM yyyy')
        .format(LocalDates.parse(entry.localDate));
    final preview = entry.body.trim().isEmpty
        ? (entry.gratitude ?? 'Empty entry')
        : entry.body.trim();
    return AppCard(
      onTap: () => openJournalEditor(context, entryId: entry.id),
      semanticLabel: 'Journal entry, $date',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(date, style: t.labelLarge)),
              if (entry.gratitude != null)
                Icon(
                  Icons.volunteer_activism_outlined,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                  semanticLabel: 'Includes gratitude',
                ),
            ],
          ),
          if (entry.prompt != null) ...[
            const SizedBox(height: 2),
            Text(
              entry.prompt!,
              style: t.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          Text(
            preview,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: t.bodyMedium,
          ),
        ],
      ),
    );
  }
}

Future<void> openJournalEditor(BuildContext context, {String? entryId}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => JournalEditorScreen(entryId: entryId),
      ),
    );
