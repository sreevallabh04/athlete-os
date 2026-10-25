import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/haptics/haptics.dart';
import '../../core/motion/motion_tokens.dart';
import '../../core/theme/hud_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/time/clock.dart';
import '../../core/widgets/emblem.dart';
import '../../core/widgets/glass.dart';
import '../../data/db/database.dart';
import '../../data/repositories/integration_status_repository.dart';
import '../../data/repositories/profile_repository.dart';

/// Whether the cold-start boot sequence may play. Off under `flutter test`;
/// override to `true` in tests/screenshots that exercise it.
final bootSequenceEnabledProvider = Provider<bool>(
  (ref) => !RuntimeEnv.isFlutterTest,
);

/// Plays the JARVIS boot sequence once per process (cold start), then
/// zoom-reveals [child]. Tap anywhere to fast-forward. Skipped entirely
/// with reduced motion.
class BootGate extends ConsumerStatefulWidget {
  const BootGate({super.key, required this.child});
  final Widget child;

  /// Resets the once-per-process latch (tests and the screenshot tool).
  static void debugReset() => _BootGateState._played = false;

  @override
  ConsumerState<BootGate> createState() => _BootGateState();
}

class _BootGateState extends ConsumerState<BootGate>
    with SingleTickerProviderStateMixin {
  static bool _played = false;

  static const total = Duration(milliseconds: 1600);
  static const exitStart = 0.8;

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: total,
  );
  bool _active = false;
  bool _decided = false;
  bool _ignited = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    final enabled = ref.read(bootSequenceEnabledProvider);
    if (enabled && !_played && !AppMotion.reduced(context)) {
      _played = true;
      _active = true;
      _c
        ..addListener(_onTick)
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed && mounted) {
            setState(() => _active = false);
          }
        })
        ..forward();
    }
  }

  void _onTick() {
    if (!_ignited && _c.value > 0.12) {
      _ignited = true;
      Haptics.light();
    }
  }

  void _skip() {
    if (_c.value >= exitStart) return;
    _c.animateTo(
      1,
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeIn,
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // The app child keeps the same position in the tree whether or not the
  // overlay is showing, so finishing the boot never rebuilds the navigator.
  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedBuilder(
          animation: _c,
          child: widget.child,
          builder: (context, child) {
            final e = !_active
                ? 1.0
                : AppMotion.emphasizedDecelerate.transform(
                    ((_c.value - exitStart) / (1 - exitStart)).clamp(0.0, 1.0),
                  );
            return Opacity(
              opacity: e,
              child: Transform.scale(scale: 0.94 + 0.06 * e, child: child),
            );
          },
        ),
        if (_active)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _skip,
            child: Semantics(
              label: 'Starting Athlete OS. Tap to skip.',
              button: true,
              child: BootSequenceView(progress: _c, exitStart: exitStart),
            ),
          ),
      ],
    );
  }
}

/// The boot visuals driven by [progress] (0..1). Public so the dev gallery
/// and screenshot tool can scrub it.
class BootSequenceView extends ConsumerWidget {
  const BootSequenceView({
    super.key,
    required this.progress,
    this.exitStart = 0.8,
  });

  final Animation<double> progress;
  final double exitStart;

  static String greetingFor(DateTime now, String? name) {
    final h = now.hour;
    final part = h < 5
        ? 'Good night'
        : h < 12
        ? 'Good morning'
        : h < 17
        ? 'Good afternoon'
        : 'Good evening';
    final n = name?.trim();
    return n == null || n.isEmpty ? '$part.' : '$part, $n.';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).now();
    String? name;
    try {
      name = ref.watch(profileProvider).value?.displayName;
    } catch (_) {
      name = null;
    }
    final statuses = ref.watch(integrationStatusesProvider);
    final checks = _checks(statuses);
    final greeting = greetingFor(now, name);
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;

    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        final p = progress.value;
        double seg(double a, double b) => ((p - a) / (b - a)).clamp(0.0, 1.0);
        final exit = AppMotion.emphasizedAccelerate.transform(
          seg(exitStart, 1),
        );
        final ignite = Curves.easeOutCubic.transform(seg(0.0, 0.28));
        final lines = AppMotion.emphasizedDecelerate.transform(seg(0.12, 0.42));
        final lift = AppMotion.emphasized.transform(seg(0.22, 0.46));
        final typed = seg(0.34, 0.6);
        final size = MediaQuery.sizeOf(context);
        final emblemY = size.height / 2 - 70 * lift;

        // Material: the overlay lives above the Navigator, so it must
        // provide its own text defaults.
        return Opacity(
          opacity: 1 - exit,
          child: Material(
            color: hud.canvasBottom,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // HUD lines + screen brackets.
                CustomPaint(
                  painter: _BootLinesPainter(
                    progress: lines,
                    y: emblemY,
                    color: hud.accent,
                  ),
                ),
                Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      18,
                      MediaQuery.paddingOf(context).top + 12,
                      18,
                      MediaQuery.paddingOf(context).bottom + 12,
                    ),
                    child: CustomPaint(
                      painter: HudFramePainter(
                        color: hud.accent.withValues(alpha: 0.55),
                        cornerLength: 22,
                        progress: lines,
                        ticks: true,
                      ),
                    ),
                  ),
                ),
                // Emblem.
                Positioned(
                  left: 0,
                  right: 0,
                  top: emblemY - 54,
                  child: Center(
                    child: Transform.scale(
                      scale: (1 + 0.35 * exit) * (1 - 0.12 * lift),
                      child: AthleteEmblem(
                        size: 108,
                        glow: 0.7 + 0.9 * ignite - 0.4 * lift,
                        detail: true,
                        semanticLabel: null,
                      ),
                    ),
                  ),
                ),
                // Greeting + system checks.
                Positioned(
                  left: AppSpacing.xxl,
                  right: AppSpacing.xxl,
                  top: emblemY + 72,
                  child: Opacity(
                    opacity: seg(0.3, 0.38),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          'ATHLETE OS',
                          style: hud.label(size: 12, color: hud.accentInk),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        _Typed(
                          text: greeting,
                          progress: typed,
                          style: t.headlineSmall!,
                          caret: hud.accent,
                        ),
                        const SizedBox(height: AppSpacing.xl),
                        for (var i = 0; i < checks.length; i++)
                          _CheckLine(
                            check: checks[i],
                            progress: seg(0.46 + i * 0.07, 0.56 + i * 0.07),
                            hud: hud,
                          ),
                        const SizedBox(height: AppSpacing.md),
                        Opacity(
                          opacity: seg(0.72, 0.78),
                          child: Text(
                            _summary(checks),
                            style: hud.mono(size: 11, color: hud.accentInk),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Honest one-line verdict: never "nominal" unless everything is online.
  static String _summary(List<_Check> checks) {
    if (checks.any((c) => c.status == 'CHECKING')) return 'RUNNING CHECKS…';
    final ok = checks.where((c) => c.tone == _Tone.ok).length;
    if (ok == checks.length) return 'ALL SYSTEMS NOMINAL';
    if (checks.any((c) => c.tone == _Tone.bad)) {
      return '$ok OF ${checks.length} ONLINE · ATTENTION NEEDED';
    }
    return '$ok OF ${checks.length} ONLINE · LOCAL MODE READY';
  }

  static List<_Check> _checks(AsyncValue<List<IntegrationConnection>> v) {
    final rows = v.value;
    IntegrationConnection? find(String id) {
      for (final r in rows ?? const <IntegrationConnection>[]) {
        if (r.provider == id) return r;
      }
      return null;
    }

    _Check line(String label, String id, {String off = 'NOT CONNECTED'}) {
      if (rows == null) return _Check(label, 'CHECKING', _Tone.muted);
      final s = find(id)?.status;
      return switch (s) {
        ConnectionStates.connected => _Check(label, 'ONLINE', _Tone.ok),
        ConnectionStates.needsSetup => _Check(label, 'NEEDS SETUP', _Tone.warn),
        ConnectionStates.awaitingCredentials => _Check(
          label,
          'AWAITING KEYS',
          _Tone.warn,
        ),
        ConnectionStates.error => _Check(label, 'ERROR', _Tone.bad),
        _ => _Check(label, off, _Tone.muted),
      };
    }

    return [
      rows == null
          ? const _Check('LOCAL DATA', 'CHECKING', _Tone.muted)
          : const _Check('LOCAL DATA', 'READY', _Tone.ok),
      line('HEALTH CONNECT', Providers.healthConnect),
      line('AI CORE', Providers.aiBackend, off: 'OFFLINE'),
      line('CALENDAR', Providers.googleCalendar),
    ];
  }
}

enum _Tone { ok, warn, bad, muted }

class _Check {
  const _Check(this.label, this.status, this.tone);
  final String label;
  final String status;
  final _Tone tone;
}

class _CheckLine extends StatelessWidget {
  const _CheckLine({
    required this.check,
    required this.progress,
    required this.hud,
  });

  final _Check check;
  final double progress;
  final HudTheme hud;

  @override
  Widget build(BuildContext context) {
    final color = switch (check.tone) {
      _Tone.ok => AppColors.success,
      _Tone.warn => AppColors.warning,
      _Tone.bad => AppColors.red,
      _Tone.muted => hud.textMuted,
    };
    final style = hud.mono(size: 11.5);
    return Opacity(
      opacity: progress,
      child: Transform.translate(
        offset: Offset(0, 6 * (1 - progress)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Text(check.label, style: style.copyWith(color: hud.text)),
              const SizedBox(width: 8),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final n = math.max(0, (box.maxWidth / 6.5).floor());
                    return Text(
                      '.' * (n * progress).round(),
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: style.copyWith(
                        color: hud.textMuted.withValues(alpha: 0.45),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              Opacity(
                opacity: progress >= 0.85 ? 1 : 0,
                child: Text(
                  check.status,
                  style: style.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
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

class _Typed extends StatelessWidget {
  const _Typed({
    required this.text,
    required this.progress,
    required this.style,
    required this.caret,
  });

  final String text;
  final double progress;
  final TextStyle style;
  final Color caret;

  @override
  Widget build(BuildContext context) {
    final n = (text.length * progress).round();
    final shown = text.substring(0, n);
    return Stack(
      alignment: Alignment.center,
      children: [
        // Reserve the final width so the line doesn't jitter while typing.
        Opacity(opacity: 0, child: Text(text, style: style, maxLines: 2)),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: shown),
              if (progress < 1)
                TextSpan(
                  text: '▍',
                  style: TextStyle(color: caret),
                ),
            ],
          ),
          style: style,
          maxLines: 2,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _BootLinesPainter extends CustomPainter {
  _BootLinesPainter({
    required this.progress,
    required this.y,
    required this.color,
  });

  final double progress;
  final double y;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final cx = size.width / 2;
    final reach = (size.width / 2 - 70) * progress;
    final paint = Paint()
      ..strokeWidth = 1
      ..shader = LinearGradient(
        colors: [
          color.withValues(alpha: 0),
          color.withValues(alpha: 0.55),
          color.withValues(alpha: 0.55),
          color.withValues(alpha: 0),
        ],
        stops: const [0, 0.38, 0.62, 1],
      ).createShader(Rect.fromLTWH(0, y, size.width, 1));
    canvas.drawLine(Offset(cx - 70 - reach, y), Offset(cx - 70, y), paint);
    canvas.drawLine(Offset(cx + 70, y), Offset(cx + 70 + reach, y), paint);
    // Tick scale.
    final tick = Paint()
      ..color = color.withValues(alpha: 0.5 * progress)
      ..strokeWidth = 1;
    for (var i = 0; i < 8; i++) {
      final d = 80.0 + i * 12;
      if (d > 70 + reach) break;
      final h = i % 4 == 0 ? 6.0 : 3.0;
      canvas.drawLine(Offset(cx - d, y - h), Offset(cx - d, y), tick);
      canvas.drawLine(Offset(cx + d, y - h), Offset(cx + d, y), tick);
    }
  }

  @override
  bool shouldRepaint(_BootLinesPainter old) =>
      old.progress != progress || old.y != y || old.color != color;
}
