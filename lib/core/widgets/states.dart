import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/provenance.dart';
import '../motion/animated_ticker.dart';
import '../motion/motion_tokens.dart';
import '../theme/hud_theme.dart';
import '../theme/tokens.dart';
import '../util/format.dart';
import 'controls.dart';
import 'loaders.dart';

/// Empty state: an icon inside a slowly scanning HUD reticle, a title,
/// optional message and call to action.
///
/// Copy voice: calm, specific, helpful ("No meals logged yet. Snap a photo
/// or search a food to start today's tally."). [eyebrow] is an optional
/// tiny mono status line above the title, e.g. `'STANDBY'`.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
    this.eyebrow,
    this.color,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;
  final String? eyebrow;

  /// Reticle/icon tint (defaults to the theme accent).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = HudTheme.of(context);
    final c = color ?? hud.accent;
    final iconSize = compact ? 22.0 : 30.0;
    return Padding(
      padding: EdgeInsets.all(compact ? AppSpacing.md : AppSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Reticle(
            size: compact ? 52 : 76,
            color: c,
            child: Icon(
              icon,
              size: iconSize,
              color: c,
              shadows: AppGlows.text(c, strength: hud.glowStrength),
            ),
          ),
          SizedBox(height: compact ? AppSpacing.sm : AppSpacing.lg),
          if (eyebrow != null) ...[
            Text(eyebrow!, style: hud.mono(size: 10.5, color: c)),
            const SizedBox(height: AppSpacing.xs),
          ],
          Text(title, style: t.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              message!,
              style: t.bodyMedium?.copyWith(color: hud.textMuted),
              textAlign: TextAlign.center,
            ),
          ],
          if (actionLabel != null) ...[
            const SizedBox(height: AppSpacing.lg),
            HudButton.secondary(
              label: actionLabel!,
              onPressed: onAction,
              compact: compact,
            ),
          ],
        ],
      ),
    );
  }
}

/// A circular reticle with brackets and a slow scanning sweep.
class _Reticle extends StatefulWidget {
  const _Reticle({
    required this.size,
    required this.color,
    required this.child,
  });
  final double size;
  final Color color;
  final Widget child;

  @override
  State<_Reticle> createState() => _ReticleState();
}

class _ReticleState extends State<_Reticle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) =>
                  CustomPaint(painter: _ReticlePainter(_c.value, widget.color)),
            ),
          ),
        ),
        widget.child,
      ],
    ),
  );
}

class _ReticlePainter extends CustomPainter {
  _ReticlePainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(
      c,
      r * 0.72,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0.16),
            color.withValues(alpha: 0.02),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: r * 0.72)),
    );
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.3);
    canvas.drawCircle(c, r * 0.72, ring);
    // Four bracket arcs at 45°.
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.7);
    final rect = Rect.fromCircle(center: c, radius: r * 0.92);
    for (var i = 0; i < 4; i++) {
      canvas.drawArc(
        rect,
        math.pi / 4 + i * math.pi / 2 - 0.3,
        0.6,
        false,
        arc,
      );
    }
    // Scanning sweep.
    final a = t * 2 * math.pi - math.pi / 2;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r * 0.72),
      a - 0.9,
      0.9,
      true,
      Paint()
        ..shader = SweepGradient(
          startAngle: a - 0.9,
          endAngle: a,
          colors: [color.withValues(alpha: 0), color.withValues(alpha: 0.22)],
        ).createShader(Rect.fromCircle(center: c, radius: r * 0.72)),
    );
  }

  @override
  bool shouldRepaint(_ReticlePainter old) => old.t != t || old.color != color;
}

class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    this.onRetry,
    this.title = 'Something went wrong',
    this.eyebrow = 'SYSTEM FAULT',
  });
  final String message;
  final VoidCallback? onRetry;

  /// Headline (keep it human: what failed, not an error code).
  final String title;
  final String? eyebrow;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: Icons.error_outline,
    title: title,
    message: message,
    eyebrow: eyebrow,
    color: AppColors.red,
    actionLabel: onRetry == null ? null : 'Retry',
    onAction: onRetry,
  );
}

/// Centered HUD spinner, optionally captioned (e.g. 'Syncing workouts…').
/// For content-shaped placeholders use `ScanlineLoader`.
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.label, this.compact = false});

  final String? label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? AppSpacing.md : AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HudSpinner(size: compact ? 26 : 36),
            if (label != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(label!, style: hud.mono(size: 11)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Small HUD chip showing where a value came from and how fresh it is,
/// e.g. "Health Connect · 12 min ago" or "AI estimate".
class SourceBadge extends StatelessWidget {
  const SourceBadge({
    super.key,
    required this.origin,
    this.asOf,
    this.isEstimate = false,
    this.now,
    this.staleAfter = const Duration(hours: 3),
  });

  final DataOrigin origin;
  final DateTime? asOf;
  final bool isEstimate;
  final DateTime? now;
  final Duration staleAfter;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final n = now ?? DateTime.now();
    final stale = asOf != null && n.difference(asOf!) > staleAfter;
    final warn = origin == DataOrigin.sample || isEstimate || stale;
    final color = warn ? AppColors.warning : hud.textMuted;
    final dot = warn ? AppColors.warning : AppColors.success;
    final parts = <String>[
      origin.label,
      if (isEstimate && origin != DataOrigin.aiEstimate) 'estimate',
      if (asOf != null) Fmt.ago(asOf!, n),
      if (stale) 'stale',
    ];
    return Semantics(
      label: 'Source: ${parts.join(', ')}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(AppRadii.xs),
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isEstimate || origin == DataOrigin.sample)
              Icon(Icons.auto_awesome_outlined, size: 11, color: color)
            else if (stale)
              Icon(Icons.schedule, size: 11, color: color)
            else
              Container(
                width: 5,
                height: 5,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: dot,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: dot.withValues(alpha: 0.8 * hud.glowStrength),
                      blurRadius: 5,
                    ),
                  ],
                ),
              ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                parts.join(' · '),
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact stat: label, big ticker number and optional sub-line.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.sub,
    this.icon,
    this.color,
  });

  final String label;
  final String value;
  final String? sub;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = HudTheme.of(context);
    final c = color ?? hud.accent;
    return Semantics(
      label: '$label: $value${sub != null ? ', $sub' : ''}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 15,
                  color: color ?? hud.textMuted,
                  shadows: color == null
                      ? null
                      : AppGlows.text(c, strength: 0.6 * hud.glowStrength),
                ),
                const SizedBox(width: 6),
              ] else ...[
                Container(
                  width: 2,
                  height: 10,
                  margin: const EdgeInsets.only(right: 6),
                  color: c.withValues(alpha: 0.8),
                ),
              ],
              Flexible(
                child: Text(
                  label,
                  style: t.labelMedium?.copyWith(color: hud.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          AnimatedTicker(
            value,
            style: t.titleLarge?.copyWith(
              fontFamily: 'InterDisplay',
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
          ),
          if (sub != null)
            Text(sub!, style: t.bodySmall?.copyWith(color: hud.textMuted)),
        ],
      ),
    );
  }
}

/// Clearly-labelled banner for data that is unavailable, stale or sample.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({
    super.key,
    required this.message,
    this.icon = Icons.info_outline,
    this.color = AppColors.info,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final IconData icon;
  final Color color;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              color.withValues(alpha: hud.isDark ? 0.14 : 0.12),
              color.withValues(alpha: hud.isDark ? 0.05 : 0.04),
            ],
          ),
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 3,
                decoration: BoxDecoration(
                  color: color,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.7 * hud.glowStrength),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.sm,
                    AppSpacing.md,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        icon,
                        color: color,
                        size: 20,
                        shadows: AppGlows.text(
                          color,
                          strength: 0.6 * hud.glowStrength,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Text(
                          message,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      if (actionLabel != null)
                        TextButton(
                          onPressed: onAction,
                          child: Text(actionLabel!),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
