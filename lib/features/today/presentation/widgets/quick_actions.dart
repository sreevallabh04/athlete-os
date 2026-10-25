import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/paths.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/util/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../data/repositories/water_repository.dart';
import '../../../life/data/mood_repository.dart';

/// One glass action tile.
class QuickAction {
  const QuickAction({
    required this.icon,
    required this.label,
    required this.sub,
    required this.color,
    required this.onTap,
    this.semanticLabel,
    this.pulseOnTap = false,
  });

  final IconData icon;
  final String label;
  final String sub;
  final Color color;
  final VoidCallback onTap;
  final String? semanticLabel;

  /// Emits a ripple ring from the icon (for instant logging actions).
  final bool pulseOnTap;
}

/// The "ease my life" row: one-tap water, meal, mood and training.
class QuickActionsRow extends ConsumerWidget {
  const QuickActionsRow({
    super.key,
    required this.waterMl,
    required this.waterGoalMl,
    required this.moodLogged,
    required this.sessionTitle,
  });

  final int waterMl;
  final int waterGoalMl;
  final bool moodLogged;

  /// Today's planned session title, if a program exists.
  final String? sessionTitle;

  static const waterStepMl = 250;

  Future<void> _addWater(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(waterRepositoryProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final id = await repo.add(waterStepMl, source: 'manual');
      Haptics.success();
      final total = waterMl + waterStepMl;
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Logged $waterStepMl ml · ${Fmt.ml(total)} of '
              '${Fmt.ml(waterGoalMl)}.',
            ),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => repo.remove(id),
            ),
          ),
        );
    } catch (_) {
      Haptics.warning();
      messenger?.showSnackBar(
        const SnackBar(content: Text('Water could not be logged.')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = [
      QuickAction(
        icon: Icons.water_drop_outlined,
        label: '+$waterStepMl ml',
        sub: '${Fmt.ml(waterMl)} / ${Fmt.ml(waterGoalMl)}',
        color: AppColors.water,
        semanticLabel: 'Log $waterStepMl millilitres of water',
        pulseOnTap: true,
        onTap: () => _addWater(context, ref),
      ),
      QuickAction(
        icon: Icons.restaurant_outlined,
        label: 'Log meal',
        sub: 'Search · scan',
        color: AppColors.calories,
        onTap: () => context.push(AppPaths.addFood),
      ),
      QuickAction(
        icon: Icons.mood_outlined,
        label: 'Check in',
        sub: moodLogged ? 'Logged today' : '10 seconds',
        color: AppColors.mood,
        semanticLabel: 'Mood check-in',
        onTap: () => showQuickMoodSheet(context),
      ),
      QuickAction(
        icon: Icons.bolt,
        label: 'Train',
        sub: sessionTitle ?? 'Open Train',
        color: AppColors.strength,
        semanticLabel: sessionTitle == null
            ? 'Open training'
            : 'Start today\'s session: $sessionTitle',
        onTap: () => sessionTitle == null
            ? context.go(AppPaths.train)
            : context.push(AppPaths.program),
      ),
    ];
    // Large text: a 2×2 grid so labels never truncate.
    final twoRows = MediaQuery.textScalerOf(context).scale(10) > 11.5;
    Widget row(List<QuickAction> list) => Row(
      children: [
        for (var i = 0; i < list.length; i++) ...[
          if (i > 0) const SizedBox(width: AppSpacing.sm),
          Expanded(child: _ActionTile(action: list[i])),
        ],
      ],
    );
    if (!twoRows) return row(actions);
    return Column(
      children: [
        row(actions.sublist(0, 2)),
        const SizedBox(height: AppSpacing.sm),
        row(actions.sublist(2)),
      ],
    );
  }
}

class _ActionTile extends StatefulWidget {
  const _ActionTile({required this.action});
  final QuickAction action;

  @override
  State<_ActionTile> createState() => _ActionTileState();
}

class _ActionTileState extends State<_ActionTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _tap() {
    final a = widget.action;
    if (a.pulseOnTap && !AppMotion.reduced(context)) _pulse.forward(from: 0);
    a.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.action;
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: a.semanticLabel ?? a.label,
      excludeSemantics: true,
      child: PressableScale(
        onTap: _tap,
        haptic: a.pulseOnTap ? PressHaptic.none : PressHaptic.light,
        pressedScale: 0.93,
        child: GlassPanel(
          accent: a.color,
          radius: AppRadii.md + 2,
          padding: const EdgeInsets.fromLTRB(6, AppSpacing.md, 6, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 30,
                width: 30,
                child: AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, child) => CustomPaint(
                    painter: _RipplePainter(t: _pulse.value, color: a.color),
                    child: child,
                  ),
                  child: Center(
                    child: GlowIcon(a.icon, size: 22, color: a.color),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                a.label,
                style: t.labelLarge?.copyWith(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 1),
              Text(
                a.sub,
                style: t.labelSmall?.copyWith(
                  color: hud.textMuted,
                  fontSize: 10,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  _RipplePainter({required this.t, required this.color});
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final c = size.center(Offset.zero);
    for (var i = 0; i < 2; i++) {
      final lt = ((t - i * 0.18) / (1 - i * 0.18)).clamp(0.0, 1.0);
      if (lt <= 0) continue;
      final e = Curves.easeOutCubic.transform(lt);
      canvas.drawCircle(
        c,
        size.width * (0.35 + 0.65 * e),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6 * (1 - e) + 0.4
          ..color = color.withValues(alpha: 0.7 * (1 - e)),
      );
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.t != t || old.color != color;
}

/// Ten-second check-in: mood and energy. Energy feeds today's session
/// readiness (a lighter session is suggested at 1–2).
Future<void> showQuickMoodSheet(BuildContext context) =>
    showHudBottomSheet<void>(
      context,
      title: 'Check in',
      builder: (_) => const _QuickMood(),
    );

class _QuickMood extends ConsumerStatefulWidget {
  const _QuickMood();

  @override
  ConsumerState<_QuickMood> createState() => _QuickMoodState();
}

class _QuickMoodState extends ConsumerState<_QuickMood> {
  int? _mood;
  int? _energy;
  bool _saving = false;

  static const moods = [
    (Icons.sentiment_very_dissatisfied, 'Awful'),
    (Icons.sentiment_dissatisfied, 'Low'),
    (Icons.sentiment_neutral, 'Okay'),
    (Icons.sentiment_satisfied, 'Good'),
    (Icons.sentiment_very_satisfied, 'Great'),
  ];

  Future<void> _save() async {
    final mood = _mood;
    if (mood == null) return;
    setState(() => _saving = true);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref
          .read(moodRepositoryProvider)
          .add(MoodInput(mood: mood, energy: _energy));
      Haptics.success();
      nav.pop();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            _energy != null && _energy! <= 2
                ? 'Noted. I will suggest a lighter session today.'
                : 'Check-in saved. Thank you.',
          ),
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      Haptics.warning();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    Widget scale(
      String title,
      int? value,
      ValueChanged<int> onPick,
      Widget Function(int i, bool selected) item,
    ) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: hud.label(size: 11)),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            for (var i = 1; i <= 5; i++) ...[
              if (i > 1) const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: PressableScale(
                  haptic: PressHaptic.selection,
                  pressedScale: 0.9,
                  onTap: () => onPick(i),
                  child: item(i, value == i),
                ),
              ),
            ],
          ],
        ),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'How are you, honestly? Ten seconds, then back to your day.',
          style: t.bodyMedium?.copyWith(color: hud.textMuted),
        ),
        const SizedBox(height: AppSpacing.lg),
        scale('MOOD', _mood, (v) => setState(() => _mood = v), (i, sel) {
          final (icon, label) = moods[i - 1];
          return Semantics(
            selected: sel,
            button: true,
            label: 'Mood $label',
            excludeSemantics: true,
            child: AnimatedContainer(
              duration: AppMotion.short,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.md),
                color: AppColors.mood.withValues(alpha: sel ? 0.16 : 0.04),
                border: Border.all(
                  color: AppColors.mood.withValues(alpha: sel ? 0.7 : 0.18),
                ),
              ),
              child: Column(
                children: [
                  AnimatedScale(
                    scale: sel ? 1.15 : 1,
                    duration: AppMotion.short,
                    child: Icon(
                      icon,
                      color: sel ? AppColors.mood : hud.textMuted,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(label, style: t.labelSmall),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: AppSpacing.lg),
        scale('ENERGY', _energy, (v) => setState(() => _energy = v), (i, sel) {
          return Semantics(
            selected: sel,
            button: true,
            label: 'Energy $i of 5',
            excludeSemantics: true,
            child: AnimatedContainer(
              duration: AppMotion.short,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                color: hud.accent.withValues(
                  alpha: _energy != null && i <= _energy! ? 0.22 : 0.04,
                ),
                border: Border.all(
                  color: hud.accent.withValues(alpha: sel ? 0.8 : 0.2),
                ),
              ),
              child: Text('$i', style: hud.number(size: 18)),
            ),
          );
        }),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Energy 1–2 makes me suggest a lighter session.',
          style: t.labelSmall?.copyWith(color: hud.textMuted),
        ),
        const SizedBox(height: AppSpacing.lg),
        HudButton(
          label: 'Save check-in',
          icon: Icons.check,
          expand: true,
          loading: _saving,
          onPressed: _mood == null ? null : _save,
        ),
        const SizedBox(height: AppSpacing.xs),
        HudButton.ghost(
          label: 'Full check-in with notes',
          onPressed: () {
            final router = GoRouter.maybeOf(context);
            Navigator.of(context).pop();
            router?.push(AppPaths.mood);
          },
        ),
      ],
    );
  }
}
