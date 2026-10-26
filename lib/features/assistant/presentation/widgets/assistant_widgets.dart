import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../application/providers.dart';
import '../../data/assistant_platform.dart';
import '../../domain/sensitivity_classifier.dart';

/// Shows an explanation BEFORE sending the user to a system settings page.
/// Returns true only when the user chose to continue.
Future<bool> explainBeforeSettings(
  BuildContext context, {
  required String title,
  required String body,
  IconData icon = Icons.info_outline,
  String continueLabel = 'Open settings',
}) async {
  final ok = await showHudBottomSheet<bool>(
    context,
    builder: (ctx) {
      final hud = HudTheme.of(ctx);
      final t = Theme.of(ctx).textTheme;
      return SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                GlowIcon(icon, framed: true, size: 20),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'BEFORE ANDROID ASKS',
                        style: hud.label(size: 11, color: hud.jarvisInk),
                      ),
                      Text(title, style: t.titleLarge),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(body, style: t.bodyMedium?.copyWith(height: 1.5)),
            const SizedBox(height: AppSpacing.xl),
            HudButton(
              label: continueLabel,
              icon: Icons.open_in_new_rounded,
              expand: true,
              onPressed: () => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: AppSpacing.sm),
            HudButton.ghost(
              label: 'Not now',
              expand: true,
              onPressed: () => Navigator.pop(ctx, false),
            ),
          ],
        ),
      );
    },
  );
  return ok == true;
}

const notificationAccessExplanation =
    'Athlete OS will be able to read notifications ONLY from the messaging '
    'apps you switch on in Assistant settings (all are off by default). '
    'Notifications from every other app are ignored immediately and never '
    'stored.\n\n'
    'What it does with them: shows summaries, prepares reply drafts, and — '
    'only when you tap Send on a specific draft — passes your reply to that '
    "notification's own Reply button (the same way smartwatches do).\n\n"
    'Captured text stays on this phone, is deleted after the retention period '
    '(7 days by default), and is sent to AI only if you allow it.\n\n'
    'Android will show its "Notification access" page next. Turn on '
    '"Athlete OS assistant". If it is greyed out (sideloaded app on Android '
    '13), open App info › ⋮ › Allow restricted settings first.\n\n'
    'You can revoke this at any time on the same page.';

/// Explains notification access, then (only if the user agrees) opens the
/// system page.
Future<void> requestNotificationAccess(
  BuildContext context,
  WidgetRef ref,
) async {
  final ok = await explainBeforeSettings(
    context,
    title: 'Allow notification access?',
    body: notificationAccessExplanation,
    icon: Icons.notifications_outlined,
  );
  if (!ok) return;
  await ref.read(assistantPlatformProvider).openListenerSettings();
  ref.invalidate(assistantDeviceStatusProvider);
}

/// Small HUD status pill: glowing dot + letter-spaced label.
class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, required this.color, this.icon});
  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.xs),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, size: 12, color: color)
          else
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.8 * hud.glowStrength),
                    blurRadius: 5,
                  ),
                ],
              ),
            ),
          const SizedBox(width: 5),
          // Rajdhani is an UPPERCASE face; ink keeps it AA on porcelain.
          Text(
            label.toUpperCase(),
            style: AppTypography.hudLabel(hud.ink(color), size: 11.5),
          ),
        ],
      ),
    );
  }
}

class FlagChips extends StatelessWidget {
  const FlagChips(this.flags, {super.key});
  final Set<SensitivityFlag> flags;

  @override
  Widget build(BuildContext context) {
    if (flags.isEmpty) {
      return const StatusPill(
        'No risk flags',
        color: AppColors.success,
        icon: Icons.check,
      );
    }
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: [
        for (final f in flags)
          StatusPill(
            f.label,
            color: f.isContent ? AppColors.danger : AppColors.warning,
            icon: f.isContent ? Icons.shield_outlined : Icons.help_outline,
          ),
      ],
    );
  }
}

/// Initials avatar for a contact/app (no third-party icons): a glass disc
/// tinted by a stable colour per app, with an optional priority halo.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({
    super.key,
    required this.name,
    required this.seed,
    this.size = 40,
    this.halo,
    this.badge,
  });

  final String name;

  /// Stable key for the tint (e.g. the package name).
  final String seed;
  final double size;

  /// Glow colour for priority (null = none).
  final Color? halo;

  /// Tiny app letter in the corner.
  final String? badge;

  static const _palette = [
    AppColors.titanium,
    AppColors.protein,
    AppColors.steps,
    AppColors.water,
    AppColors.competition,
    AppColors.carbs,
    AppColors.habit,
  ];

  static Color tintFor(String seed) =>
      _palette[seed.codeUnits.fold<int>(0, (a, b) => a * 31 + b).abs() %
          _palette.length];

  static String initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    final first = parts.first.characters.first;
    final second = parts.length > 1 ? parts[1].characters.first : '';
    return (first + second).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final c = tintFor(seed);
    return SizedBox.square(
      dimension: size + 6,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (halo != null)
            Container(
              width: size + 6,
              height: size + 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: halo!.withValues(alpha: 0.9),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: halo!.withValues(alpha: 0.45 * hud.glowStrength),
                    blurRadius: 12,
                  ),
                ],
              ),
            ),
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [c.withValues(alpha: 0.30), c.withValues(alpha: 0.08)],
              ),
              border: Border.all(color: c.withValues(alpha: 0.5)),
            ),
            child: Text(
              initials(name),
              style: AppTypography.hudLabel(
                hud.isDark ? Color.lerp(c, Colors.white, 0.45)! : hud.text,
                size: size * 0.38,
              ),
            ),
          ),
          if (badge != null)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: size * 0.42,
                height: size * 0.42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: hud.isDark ? AppColors.darkSurface : Colors.white,
                  border: Border.all(color: c.withValues(alpha: 0.7)),
                ),
                child: Text(
                  badge!.characters.first.toUpperCase(),
                  style: AppTypography.hudLabel(c, size: size * 0.24),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The emergency stop, styled as an arc-reactor master switch: a large
/// ringed button that glows green while automation is allowed and red when
/// stopped. One tap flips it (with a heavy haptic).
class KillSwitchCard extends ConsumerWidget {
  const KillSwitchCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final killed =
        ref.watch(assistantSettingsProvider).value?.killSwitch ?? false;
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    final c = killed ? AppColors.danger : AppColors.success;
    Future<void> flip() async {
      if (killed) {
        Haptics.success();
      } else {
        Haptics.heavy();
      }
      try {
        await ref.read(assistantControllerProvider).setKillSwitch(!killed);
      } catch (_) {
        // The setting itself is saved; a native step failed. Say so instead
        // of failing silently on an emergency control.
        if (!context.mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'Emergency stop saved, but the system listener could not be '
              'fully updated. Check notification access in Capabilities.',
            ),
          ),
        );
      }
    }

    return AppCard(
      accent: c,
      glow: killed,
      child: Row(
        children: [
          Semantics(
            button: true,
            toggled: killed,
            label: killed ? 'Resume assistant' : 'Emergency stop',
            excludeSemantics: true,
            onTap: flip,
            child: PressableScale(
              key: const Key('kill_switch_button'),
              onTap: flip,
              haptic: PressHaptic.none,
              pressedScale: 0.92,
              child: _Reactor(color: c, engaged: killed),
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  killed ? 'MASTER SWITCH · SAFE' : 'MASTER SWITCH · ARMED',
                  style: hud.label(size: 11, color: c),
                ),
                const SizedBox(height: 2),
                AnimatedSwitcher(
                  duration: AppMotion.medium,
                  child: Text(
                    killed ? 'Resume assistant' : 'Emergency stop',
                    key: ValueKey(killed),
                    style: t.titleLarge,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  killed
                      ? 'Emergency stop is ON — nothing is captured, drafted '
                            'or sent.'
                      : 'Assistant automation is allowed by your settings. '
                            'Tap the reactor to stop everything instantly.',
                  style: t.bodySmall?.copyWith(color: hud.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Reactor extends StatefulWidget {
  const _Reactor({required this.color, required this.engaged});
  final Color color;
  final bool engaged;

  @override
  State<_Reactor> createState() => _ReactorState();
}

class _ReactorState extends State<_Reactor>
    with TickerProviderStateMixin, HudTimeDriver {
  @override
  int get fps => 30;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    return SizedBox.square(
      dimension: 88,
      child: CustomPaint(
        painter: _ReactorPainter(
          time: hudTime,
          color: widget.color,
          engaged: widget.engaged,
          glow: hud.glowStrength,
        ),
        child: Center(
          child: Icon(
            widget.engaged
                ? Icons.play_arrow_rounded
                : Icons.power_settings_new_rounded,
            size: 30,
            color: Colors.white,
            shadows: AppGlows.text(widget.color, strength: hud.glowStrength),
          ),
        ),
      ),
    );
  }
}

class _ReactorPainter extends CustomPainter {
  _ReactorPainter({
    required this.time,
    required this.color,
    required this.engaged,
    required this.glow,
  }) : super(repaint: time);

  final ValueNotifier<double> time;
  final Color color;
  final bool engaged;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.drawCircle(
      c,
      r * 0.62,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0.85),
            color.withValues(alpha: 0.35),
            color.withValues(alpha: 0.0),
          ],
          stops: const [0, 0.6, 1],
        ).createShader(Rect.fromCircle(center: c, radius: r * 0.62)),
    );
    canvas.drawCircle(
      c,
      r * 0.62,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color.withValues(alpha: 0.9),
    );
    // Segmented outer ring, rotating slowly (faster when engaged).
    final spin = t * (engaged ? 1.4 : 0.35);
    final seg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = color.withValues(alpha: 0.75);
    for (var i = 0; i < 8; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r * 0.84),
        spin + i * math.pi / 4,
        math.pi / 4 - 0.22,
        false,
        seg,
      );
    }
    final tick = Paint()
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.35);
    for (var i = 0; i < 36; i++) {
      final a = i * math.pi / 18;
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + d * r * 0.93, c + d * r, tick);
    }
    if (engaged) {
      final ph = (t * 0.8) % 1.0;
      canvas.drawCircle(
        c,
        r * (0.62 + 0.38 * ph),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * (1 - ph)
          ..color = color.withValues(alpha: 0.6 * (1 - ph) * glow),
      );
    }
  }

  @override
  bool shouldRepaint(_ReactorPainter old) =>
      old.color != color || old.engaged != engaged;
}

String appLabelFor(String pkg, Map<String, String> labels) =>
    labels[pkg] ?? pkg;

String formatMinutes(int m) {
  final h = m ~/ 60, mm = m % 60;
  return '${h.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
}

/// Platform convenience for widgets that only need the interface.
AssistantPlatform platformOf(WidgetRef ref) =>
    ref.read(assistantPlatformProvider);
