import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/tokens.dart';
import '../../domain/crisis_detector.dart';
import '../../domain/habit_models.dart';

/// Calm, non-judgemental support card shown when a note clearly expresses
/// severe distress. Never blocks saving and makes no diagnosis.
class SupportCard extends StatelessWidget {
  const SupportCard({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      label: 'Support information',
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: AppColors.info.withValues(alpha: 0.10),
          borderRadius: AppRadii.card,
          border: Border.all(color: AppColors.info.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.favorite_outline, color: AppColors.info),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'You don\'t have to carry this alone',
                    style: t.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'It sounds like things may be really hard right now. Consider '
              'reaching out to someone you trust and telling them how you '
              'feel. If you are in immediate danger, please contact your '
              'local emergency services now.',
              style: t.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'You can find a free, confidential crisis line in your country '
              'at findahelpline.com.',
              style: t.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.tonalIcon(
              onPressed: () => launchUrl(
                Uri.parse(crisisHelplineUrl),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Find a helpline'),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Your entry is still saved, privately on this device.',
              style: t.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData moodIcon(int mood) => switch (mood) {
  1 => Icons.sentiment_very_dissatisfied,
  2 => Icons.sentiment_dissatisfied,
  3 => Icons.sentiment_neutral,
  4 => Icons.sentiment_satisfied,
  _ => Icons.sentiment_very_satisfied,
};

/// Neutral-to-warm scale; low moods are not shown in alarming red.
Color moodColor(int mood) => switch (mood) {
  1 => const Color(0xFF94A3B8),
  2 => const Color(0xFF7DD3FC),
  3 => const Color(0xFFA5B4FC),
  4 => const Color(0xFF86EFAC),
  _ => AppColors.mood,
};

Color moodColorFor(double mean) => moodColor(mean.round().clamp(1, 5));

/// Seven toggle chips for picking weekdays (bit0 = Monday).
class WeekdayPicker extends StatelessWidget {
  const WeekdayPicker({
    super.key,
    required this.mask,
    required this.onChanged,
    this.single = false,
  });

  final int mask;
  final ValueChanged<int> onChanged;

  /// Exactly one day may be selected (weekly summary).
  final bool single;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: [
        for (var d = 1; d <= 7; d++)
          Semantics(
            label: weekdayShort[d - 1],
            selected: maskHasWeekday(mask, d),
            excludeSemantics: true,
            child: FilterChip(
              showCheckmark: false,
              label: Text(weekdayShort[d - 1]),
              selected: maskHasWeekday(mask, d),
              onSelected: (on) {
                if (single) {
                  onChanged(weekdayBit(d));
                  return;
                }
                final next = on ? mask | weekdayBit(d) : mask & ~weekdayBit(d);
                if (next & allDaysMask != 0) onChanged(next);
              },
            ),
          ),
      ],
    );
  }
}

Future<int?> pickMinutes(BuildContext context, int initial) async {
  final t = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: (initial ~/ 60) % 24, minute: initial % 60),
  );
  return t == null ? null : t.hour * 60 + t.minute;
}

/// Editable list of times of day (minutes after midnight).
class TimesEditor extends StatelessWidget {
  const TimesEditor({
    super.key,
    required this.times,
    required this.onChanged,
    this.maxTimes = 6,
    this.addLabel = 'Add time',
  });

  final List<int> times;
  final ValueChanged<List<int>> onChanged;
  final int maxTimes;
  final String addLabel;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final m in times)
          InputChip(
            label: Text(formatMinutes(m)),
            tooltip: 'Change time',
            onPressed: () async {
              final v = await pickMinutes(context, m);
              if (v == null) return;
              onChanged(
                ({...times}
                      ..remove(m)
                      ..add(v))
                    .toList()
                  ..sort(),
              );
            },
            onDeleted: () => onChanged([...times]..remove(m)),
            deleteButtonTooltipMessage: 'Remove ${formatMinutes(m)}',
          ),
        if (times.length < maxTimes)
          ActionChip(
            avatar: const Icon(Icons.add, size: 18),
            label: Text(addLabel),
            onPressed: () async {
              final v = await pickMinutes(
                context,
                times.isEmpty ? 9 * 60 : (times.last + 60) % 1440,
              );
              if (v == null) return;
              onChanged(({...times, v}).toList()..sort());
            },
          ),
      ],
    );
  }
}

/// Small rounded label, e.g. "auto" or "Up next".
class TagPill extends StatelessWidget {
  const TagPill(this.text, {super.key, this.color, this.icon});
  final String text;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: AppRadii.chip,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: c),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: c, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Labelled 1..5 selector with large touch targets.
class ScaleSelector extends StatelessWidget {
  const ScaleSelector({
    super.key,
    required this.label,
    required this.labels,
    required this.value,
    required this.onChanged,
    this.color = AppColors.brand,
  });

  final String label;
  final Map<int, String> labels;
  final int? value;
  final ValueChanged<int?> onChanged;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: t.labelLarge)),
            Text(
              value == null ? 'Not set' : labels[value]!,
              style: t.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            for (var i = 1; i <= 5; i++) ...[
              if (i > 1) const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Semantics(
                  button: true,
                  selected: value == i,
                  label: '$label: ${labels[i]}',
                  excludeSemantics: true,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                    onTap: () => onChanged(value == i ? null : i),
                    child: AnimatedContainer(
                      duration: AppDurations.fast,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: value == i
                            ? color.withValues(alpha: 0.25)
                            : scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(AppRadii.sm),
                        border: Border.all(
                          color: value == i ? color : Colors.transparent,
                        ),
                      ),
                      child: Text('$i', style: t.titleSmall),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
