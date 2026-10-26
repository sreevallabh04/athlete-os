import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/widgets/widgets.dart';
import 'common.dart';

/// Horizontal strip of recent days (today at the right edge). Each day shows
/// a micro calorie ring for logged days; tap to jump, with a selection tick.
class DayStrip extends StatefulWidget {
  const DayStrip({
    super.key,
    required this.today,
    required this.selected,
    required this.onSelect,
    this.progress = const {},
    this.days = 28,
  });

  final String today;
  final String selected;
  final ValueChanged<String> onSelect;

  /// Calorie consumed/target ratio per logged day (missing = not logged).
  final Map<String, double> progress;
  final int days;

  @override
  State<DayStrip> createState() => _DayStripState();
}

class _DayStripState extends State<DayStrip> {
  static const _cell = 48.0;
  static const _gap = 6.0;
  final _scroll = ScrollController();

  int get _selectedIndex {
    final diff = LocalDates.parse(widget.today)
        .difference(LocalDates.parse(widget.selected))
        .inDays;
    return diff.clamp(0, widget.days - 1);
  }

  @override
  void didUpdateWidget(DayStrip old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) _reveal();
  }

  void _reveal() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final itemStart = AppSpacing.gutter + _selectedIndex * (_cell + _gap);
    final itemEnd = itemStart + _cell;
    double? target;
    if (itemStart < pos.pixels + 8) {
      target = itemStart - 8;
    } else if (itemEnd > pos.pixels + pos.viewportDimension - 8) {
      target = itemEnd - pos.viewportDimension + 8;
    }
    if (target == null) return;
    target = target.clamp(0, pos.maxScrollExtent);
    if (AppMotion.reduced(context)) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(
        target,
        duration: AppMotion.medium,
        curve: AppMotion.emphasizedDecelerate,
      );
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.4);
    // The strip bleeds to the screen edges (cells rest on the page gutter and
    // scroll off at the glass edge) instead of being sliced at the gutter.
    return SizedBox(
      height: 76 * scale,
      child: LayoutBuilder(
        builder: (context, box) => OverflowBox(
          minWidth: box.maxWidth + 2 * AppSpacing.gutter,
          maxWidth: box.maxWidth + 2 * AppSpacing.gutter,
          child: _list(),
        ),
      ),
    );
  }

  Widget _list() => ListView.separated(
    controller: _scroll,
    scrollDirection: Axis.horizontal,
    reverse: true,
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
    physics: const BouncingScrollPhysics(),
    itemCount: widget.days,
    separatorBuilder: (_, _) => const SizedBox(width: _gap),
    itemBuilder: (context, i) {
      final date = LocalDates.addDays(widget.today, -i);
      return _DayCell(
        date: date,
        isToday: i == 0,
        selected: date == widget.selected,
        progress: widget.progress[date],
        width: _cell,
        onTap: () => widget.onSelect(date),
        semantic: friendlyDate(date, widget.today),
      );
    },
  );
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.isToday,
    required this.selected,
    required this.progress,
    required this.width,
    required this.onTap,
    required this.semantic,
  });

  final String date;
  final bool isToday;
  final bool selected;
  final double? progress;
  final double width;
  final VoidCallback onTap;
  final String semantic;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final d = LocalDates.parse(date);
    final reduced = AppMotion.reduced(context);
    return Semantics(
      button: true,
      selected: selected,
      label:
          '$semantic${progress == null ? ', nothing logged' : ', ${(progress! * 100).round()} percent of calorie target'}',
      excludeSemantics: true,
      onTap: selected ? null : onTap,
      child: PressableScale(
        onTap: selected ? null : onTap,
        haptic: PressHaptic.selection,
        pressedScale: 0.92,
        child: AnimatedContainer(
          duration: reduced ? Duration.zero : AppMotion.medium,
          curve: AppMotion.standard,
          width: width,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            color: selected
                ? hud.accent.withValues(alpha: hud.isDark ? 0.14 : 0.12)
                : hud.text.withValues(alpha: hud.isDark ? 0.025 : 0.04),
            border: Border.all(
              color: selected
                  ? hud.accent.withValues(alpha: 0.65)
                  : hud.hairline.withValues(alpha: 0.12),
            ),
            boxShadow: selected
                ? AppGlows.soft(hud.accent, strength: hud.glowStrength)
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isToday
                    ? 'NOW'
                    : DateFormat.E().format(d).substring(0, 2).toUpperCase(),
                style: hud.label(
                  size: 10,
                  color: isToday ? hud.accentInk : hud.textMuted,
                ),
              ),
              Text(
                '${d.day}',
                style: t.titleSmall?.copyWith(
                  color: selected ? hud.text : hud.text.withValues(alpha: 0.8),
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              SizedBox.square(
                dimension: 14,
                child: CustomPaint(
                  painter: _MicroRingPainter(progress: progress, hud: hud),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MicroRingPainter extends CustomPainter {
  _MicroRingPainter({required this.progress, required this.hud});

  final double? progress;
  final HudTheme hud;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 1.5;
    final p = progress;
    if (p == null) {
      canvas.drawCircle(
        c,
        1.6,
        Paint()..color = hud.textMuted.withValues(alpha: 0.4),
      );
      return;
    }
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..color = AppColors.calories.withValues(alpha: 0.18);
    canvas.drawCircle(c, r, track);
    final over = p > 1.1;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..color = over ? AppColors.over : AppColors.calories;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -math.pi / 2,
      p.clamp(0.0, 1.0) * 2 * math.pi,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_MicroRingPainter old) =>
      old.progress != progress || old.hud != hud;
}
