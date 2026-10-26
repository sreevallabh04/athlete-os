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
import 'widgets/life_widgets.dart';

class JournalScreen extends ConsumerWidget {
  const JournalScreen({super.key});

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final ok = await confirmHud(
      context,
      icon: Icons.ios_share,
      title: 'Export your journal?',
      message:
          'This creates a plain-text copy of every entry and opens the share '
          'sheet. Only share it with apps or people you trust.',
      confirmLabel: 'Export',
    );
    if (!ok) return;
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
    final now = ref.watch(clockProvider).now();
    final today = LocalDates.key(now);
    final prompt = promptFor(now.difference(DateTime(2024)).inDays);
    return AppPage(
      title: 'Journal',
      eyebrow: 'PRIVATE · ON THIS DEVICE',
      actions: [
        IconButton(
          tooltip: 'Export journal as text',
          icon: const Icon(Icons.ios_share),
          onPressed: () => _export(context, ref),
        ),
      ],
      bottomAction: HudButton(
        expand: true,
        label: 'Write',
        icon: Icons.edit_outlined,
        onPressed: () => openJournalEditor(context),
      ),
      children: [
        const _PrivacyCard(),
        ...entries.when(
          loading: () => const [
            SizedBox(height: AppSpacing.xl),
            ScanlineLoader(lines: 4),
          ],
          error: (e, _) => [
            ErrorState(
              message: 'Your journal couldn\'t be loaded.',
              onRetry: () => ref.invalidate(journalEntriesProvider),
            ),
          ],
          data: (list) => [
            if (list.isNotEmpty) _Stats(entries: list, today: today),
            const SectionHeader('Entries'),
            if (list.isEmpty)
              AppCard(
                child: Column(
                  children: [
                    EmptyState(
                      icon: Icons.menu_book_outlined,
                      eyebrow: 'BLANK PAGE',
                      title: 'Nothing written yet',
                      message:
                          'A few lines are plenty. Prompts are there if you '
                          'want them.',
                      actionLabel: 'Write an entry',
                      onAction: () => openJournalEditor(context),
                    ),
                    _PromptSuggestion(prompt: prompt),
                  ],
                ),
              )
            else
              StaggeredList(
                gap: AppSpacing.sm,
                children: [
                  for (final e in list)
                    _JournalEntryCard(key: ValueKey(e.id), entry: e),
                ],
              ),
            const SizedBox(height: 96),
          ],
        ),
      ],
    );
  }
}

class _PromptSuggestion extends StatelessWidget {
  const _PromptSuggestion({required this.prompt});
  final String prompt;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return PressableScale(
      onTap: () => openJournalEditor(context, prompt: prompt),
      child: GlassPanel(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            GlowIcon(Icons.lightbulb_outline, size: 18, color: hud.accent),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('TODAY\'S PROMPT', style: hud.label(size: 10.5)),
                  const SizedBox(height: 2),
                  Text(
                    prompt,
                    style: t.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: hud.textMuted),
          ],
        ),
      ),
    );
  }
}

class _PrivacyCard extends StatelessWidget {
  const _PrivacyCard();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return AppCard(
      brackets: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const GlowIcon(
                Icons.lock_outline,
                color: AppColors.habit,
                framed: true,
                size: 20,
              ),
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
                      style: t.bodyMedium?.copyWith(color: hud.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Divider(
              height: 1,
              color: hud.hairline.withValues(alpha: 0.12),
            ),
          ),
          const AiJournalConsentCard(embedded: true),
        ],
      ),
    );
  }
}

/// Toggle bound to `SettingKeys.aiJournalConsent` (default off). Turning it
/// on always shows the disclosure first.
class AiJournalConsentCard extends ConsumerWidget {
  const AiJournalConsentCard({super.key, this.embedded = false});

  /// Render without its own card (inside another surface).
  final bool embedded;

  static Future<void> set(BuildContext context, WidgetRef ref, bool on) async {
    if (on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const GlowIcon(Icons.auto_awesome_outlined, size: 26),
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
            HudButton(
              label: 'Allow',
              compact: true,
              onPressed: () => Navigator.pop(ctx, true),
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
    final hud = context.hud;
    final row = HudRow(
      leading: GlowIcon(
        Icons.auto_awesome_outlined,
        size: 20,
        color: on ? hud.accent : hud.textMuted,
        glow: on ? 1 : 0,
      ),
      title: 'AI journal analysis',
      subtitle: on
          ? 'On: the AI coach may read entries when you ask it to.'
          : 'Off: journal text never leaves this device.',
      trailing: HudToggle(
        key: const Key('ai-journal-consent'),
        value: on,
        semanticLabel: 'AI journal analysis',
        onChanged: (v) => set(context, ref, v),
      ),
    );
    return embedded ? row : AppCard(child: row);
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.entries, required this.today});
  final List<JournalEntry> entries;
  final String today;

  @override
  Widget build(BuildContext context) {
    final monthPrefix = today.substring(0, 7);
    final thisMonth = entries.where((e) => e.localDate.startsWith(monthPrefix));
    final days = entries.map((e) => e.localDate).toSet();
    final words = entries.fold<int>(
      0,
      (a, e) => a + _wordCount('${e.body} ${e.gratitude ?? ''}'),
    );
    final last = entries
        .map((e) => e.localDate)
        .reduce((a, b) => a.compareTo(b) > 0 ? a : b);
    final ago = LocalDates.parse(today)
        .difference(LocalDates.parse(last))
        .inDays;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: AppCard(
        child: Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Entries',
                value: '${entries.length}',
                sub: '${thisMonth.length} this month',
              ),
            ),
            Expanded(
              child: StatTile(
                label: 'Words',
                value: _group(words),
                sub: '${days.length} days written',
              ),
            ),
            Expanded(
              child: StatTile(
                label: 'Last entry',
                value: ago == 0 ? 'Today' : '${ago}d ago',
                sub: DateFormat('d MMM').format(LocalDates.parse(last)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _group(int v) => NumberFormat.decimalPattern().format(v);
}

int _wordCount(String s) =>
    s.trim().isEmpty ? 0 : s.trim().split(RegExp(r'\s+')).length;

class _JournalEntryCard extends StatelessWidget {
  const _JournalEntryCard({super.key, required this.entry});
  final JournalEntry entry;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final d = LocalDates.parse(entry.localDate);
    final date = DateFormat('EEE d MMM yyyy').format(d);
    final preview = entry.body.trim().isEmpty
        ? (entry.gratitude ?? 'Empty entry')
        : entry.body.trim();
    final words = _wordCount('${entry.body} ${entry.gratitude ?? ''}');
    return AppCard(
      onTap: () => openJournalEditor(context, entryId: entry.id),
      semanticLabel: 'Journal entry, $date',
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Date block.
          Container(
            width: 52,
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: Border.all(color: hud.accent.withValues(alpha: 0.3)),
              color: hud.accent.withValues(alpha: 0.05),
            ),
            child: Column(
              children: [
                Text(
                  DateFormat('MMM').format(d).toUpperCase(),
                  style: hud.label(size: 10, color: hud.accentInk),
                ),
                Text('${d.day}', style: hud.number(size: 26)),
                Text(
                  DateFormat('EEE').format(d).toUpperCase(),
                  style: hud.label(size: 9.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.prompt != null) ...[
                  Text(
                    entry.prompt!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(
                      color: hud.textMuted,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                Text(
                  preview,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Text('$words WORDS', style: hud.mono(size: 10)),
                    if (entry.gratitude != null) ...[
                      const SizedBox(width: AppSpacing.sm),
                      Icon(
                        Icons.volunteer_activism_outlined,
                        size: 13,
                        color: AppColors.mood.withValues(alpha: 0.8),
                        semanticLabel: 'Includes gratitude',
                      ),
                      const SizedBox(width: 3),
                      Text('GRATITUDE', style: hud.label(size: 9.5)),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> openJournalEditor(
  BuildContext context, {
  String? entryId,
  String? prompt,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) =>
        JournalEditorScreen(entryId: entryId, initialPrompt: prompt),
  ),
);
