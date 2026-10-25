import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../data/mood_repository.dart';
import '../domain/crisis_detector.dart';
import '../domain/mood_stats.dart';
import 'widgets/life_widgets.dart';

Future<void> showMoodCheckIn(BuildContext context) async {
  final distressed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const MoodCheckInSheet(),
  );
  if (distressed == true && context.mounted) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.all(AppSpacing.md),
        content: const SingleChildScrollView(child: SupportCard()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// Quick mood check-in. Pops with `true` when the note suggested severe
/// distress (so the caller can keep showing support), otherwise `false`.
class MoodCheckInSheet extends ConsumerStatefulWidget {
  const MoodCheckInSheet({super.key});

  @override
  ConsumerState<MoodCheckInSheet> createState() => _MoodCheckInSheetState();
}

class _MoodCheckInSheetState extends ConsumerState<MoodCheckInSheet> {
  int? _mood;
  int? _energy;
  int? _stress;
  int? _sleep;
  final _tags = <String>{};
  final _note = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _note.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final mood = _mood;
    if (mood == null) return;
    setState(() => _saving = true);
    await ref
        .read(moodRepositoryProvider)
        .add(
          MoodInput(
            mood: mood,
            energy: _energy,
            stress: _stress,
            sleepQuality: _sleep,
            tags: _tags.toList(),
            note: _note.text,
          ),
        );
    if (mounted) Navigator.of(context).pop(detectsSevereDistress(_note.text));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final distress = detectsSevereDistress(_note.text);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          0,
          AppSpacing.gutter,
          AppSpacing.xl,
        ),
        children: [
          Text('How are you feeling?', style: t.titleLarge),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              for (var m = 1; m <= 5; m++)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: _mood == m,
                    label: 'Mood ${moodLabels[m]}',
                    excludeSemantics: true,
                    child: InkWell(
                      key: Key('mood-$m'),
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      onTap: () => setState(() => _mood = m),
                      child: AnimatedContainer(
                        duration: AppDurations.fast,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.sm,
                        ),
                        decoration: BoxDecoration(
                          color: _mood == m
                              ? moodColor(m).withValues(alpha: 0.22)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(AppRadii.md),
                          border: Border.all(
                            color: _mood == m
                                ? moodColor(m)
                                : scheme.outlineVariant,
                          ),
                        ),
                        child: Column(
                          children: [
                            Icon(moodIcon(m), size: 34, color: moodColor(m)),
                            const SizedBox(height: 4),
                            Text(
                              moodLabels[m]!,
                              style: t.labelSmall,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          ScaleSelector(
            label: 'Energy',
            labels: energyLabels,
            value: _energy,
            onChanged: (v) => setState(() => _energy = v),
            color: AppColors.calories,
          ),
          const SizedBox(height: AppSpacing.lg),
          ScaleSelector(
            label: 'Stress',
            labels: stressLabels,
            value: _stress,
            onChanged: (v) => setState(() => _stress = v),
            color: AppColors.info,
          ),
          const SizedBox(height: AppSpacing.lg),
          ScaleSelector(
            label: 'Sleep quality (last night)',
            labels: sleepQualityLabels,
            value: _sleep,
            onChanged: (v) => setState(() => _sleep = v),
            color: AppColors.sleep,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Emotions', style: t.labelLarge),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final tag in emotionTags)
                FilterChip(
                  label: Text(tag),
                  selected: _tags.contains(tag),
                  onSelected: (on) =>
                      setState(() => on ? _tags.add(tag) : _tags.remove(tag)),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _note,
            minLines: 2,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              hintText: 'Anything on your mind?',
            ),
          ),
          if (distress) ...[
            const SizedBox(height: AppSpacing.md),
            const SupportCard(),
          ],
          const SizedBox(height: AppSpacing.lg),
          FilledButton(
            onPressed: _mood == null || _saving ? null : _save,
            child: Text(
              _mood == null ? 'Choose a mood to save' : 'Save check-in',
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Stored only on this device.',
            textAlign: TextAlign.center,
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
