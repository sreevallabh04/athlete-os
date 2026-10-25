import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/tokens.dart';

/// Fades + slides its child in after a short index-based stagger.
class Stagger extends StatelessWidget {
  const Stagger({super.key, required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final delay = 60 * index.clamp(0, 10);
    final total = 320 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, (1 - v) * 18),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Big tappable answer card (single or multi select).
class OptionCard extends StatelessWidget {
  const OptionCard({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.icon,
    this.multi = false,
    this.accent,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool selected;
  final bool multi;
  final VoidCallback onTap;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final c = accent ?? scheme.primary;
    return Semantics(
      selected: selected,
      button: true,
      label: title,
      child: AnimatedContainer(
        duration: AppDurations.medium,
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: selected ? c.withValues(alpha: 0.14) : scheme.surface,
          borderRadius: AppRadii.card,
          border: Border.all(
            color: selected ? c : scheme.outlineVariant,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: AppRadii.card,
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.md + 2,
              ),
              child: Row(
                children: [
                  if (icon != null) ...[
                    AnimatedContainer(
                      duration: AppDurations.medium,
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: c.withValues(alpha: selected ? 0.22 : 0.08),
                        borderRadius: BorderRadius.circular(AppRadii.sm),
                      ),
                      child: Icon(icon, color: c, size: 22),
                    ),
                    const SizedBox(width: AppSpacing.md),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: t.titleSmall),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            style: t.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  AnimatedScale(
                    scale: selected ? 1 : 0.6,
                    duration: AppDurations.medium,
                    curve: Curves.easeOutBack,
                    child: AnimatedOpacity(
                      opacity: selected ? 1 : (multi ? 0.35 : 0),
                      duration: AppDurations.fast,
                      child: Icon(
                        multi
                            ? (selected
                                  ? Icons.check_box
                                  : Icons.check_box_outline_blank)
                            : Icons.check_circle,
                        color: c,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Numeric stepper with a large animated value.
class NumberStepper extends StatelessWidget {
  const NumberStepper({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.step,
    required this.min,
    required this.max,
    this.format,
    this.unit = '',
    this.helper,
  });

  final String label;
  final double value;
  final double step;
  final double min;
  final double max;
  final String unit;
  final String? helper;
  final String Function(double)? format;
  final ValueChanged<double> onChanged;

  String _fmt(double v) =>
      format?.call(v) ??
      (v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    double clamp(double v) =>
        double.parse(v.clamp(min, max).toStringAsFixed(2));
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: AppRadii.card,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          Text(
            label.toUpperCase(),
            style: t.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              IconButton.filledTonal(
                tooltip: 'Decrease $label',
                onPressed: value <= min
                    ? null
                    : () => onChanged(clamp(value - step)),
                icon: const Icon(Icons.remove),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: AppDurations.fast,
                  transitionBuilder: (child, a) => ScaleTransition(
                    scale: Tween(begin: 0.85, end: 1.0).animate(a),
                    child: FadeTransition(opacity: a, child: child),
                  ),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: _fmt(value),
                          style: t.displaySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (unit.isNotEmpty)
                          TextSpan(
                            text: ' $unit',
                            style: t.titleMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    key: ValueKey(value),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Increase $label',
                onPressed: value >= max
                    ? null
                    : () => onChanged(clamp(value + step)),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          if (helper != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              helper!,
              textAlign: TextAlign.center,
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

/// Row showing a time of day; tapping opens the time picker.
class TimeTile extends StatelessWidget {
  const TimeTile({
    super.key,
    required this.label,
    required this.minutes,
    required this.onChanged,
    this.icon = Icons.schedule,
  });

  final String label;
  final int minutes;
  final IconData icon;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final tod = TimeOfDay(hour: (minutes ~/ 60) % 24, minute: minutes % 60);
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.card,
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: ListTile(
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.card),
        leading: Icon(icon, color: scheme.primary),
        title: Text(label),
        trailing: Text(tod.format(context), style: t.titleMedium),
        onTap: () async {
          final picked = await showTimePicker(
            context: context,
            initialTime: tod,
          );
          if (picked != null) onChanged(picked.hour * 60 + picked.minute);
        },
      ),
    );
  }
}

/// Editable list of short strings shown as chips (restrictions, dislikes).
class ChipListEditor extends StatefulWidget {
  const ChipListEditor({
    super.key,
    required this.label,
    required this.values,
    required this.onChanged,
    this.hint,
    this.suggestions = const [],
  });

  final String label;
  final String? hint;
  final List<String> values;
  final List<String> suggestions;
  final ValueChanged<List<String>> onChanged;

  @override
  State<ChipListEditor> createState() => _ChipListEditorState();
}

class _ChipListEditorState extends State<ChipListEditor> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _add(String v) {
    final s = v.trim();
    if (s.isEmpty || widget.values.contains(s)) return;
    widget.onChanged([...widget.values, s]);
    _c.clear();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: t.titleSmall),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final v in widget.values)
              InputChip(
                label: Text(v),
                onDeleted: () => widget.onChanged(
                  widget.values.where((e) => e != v).toList(),
                ),
              ),
            for (final s in widget.suggestions)
              if (!widget.values.contains(s))
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: Text(s),
                  onPressed: () => _add(s),
                ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _c,
          decoration: InputDecoration(
            hintText: widget.hint,
            isDense: true,
            suffixIcon: IconButton(
              tooltip: 'Add',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => _add(_c.text),
            ),
          ),
          onSubmitted: _add,
        ),
      ],
    );
  }
}
