import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../../data/repositories/water_repository.dart';
import '../application/providers.dart';
import '../domain/nutrition_calc.dart';
import 'nutrition_screen.dart' show hydrationHeroTag;
import 'widgets/amount_sheet.dart';
import 'widgets/common.dart';
import 'widgets/nutrition_hud.dart';

class HydrationScreen extends ConsumerStatefulWidget {
  const HydrationScreen({super.key});

  @override
  ConsumerState<HydrationScreen> createState() => _HydrationScreenState();
}

class _HydrationScreenState extends ConsumerState<HydrationScreen> {
  late final GoalPulse _pulse = GoalPulse(
    'water',
    onFired: () {
      if (mounted) showSnack(context, 'Water goal reached for today.');
    },
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _add(int ml) async {
    try {
      final repo = ref.read(waterRepositoryProvider);
      final id = await repo.add(ml);
      Haptics.success();
      if (!mounted) return;
      showSnack(
        context,
        'Added ${Fmt.ml(ml)}',
        action: SnackBarAction(label: 'Undo', onPressed: () => repo.remove(id)),
      );
    } catch (e) {
      if (mounted) showSnack(context, redactSecrets('$e'));
    }
  }

  Future<void> _custom() async {
    final ml = await showHudBottomSheet<int>(
      context,
      title: 'Add water',
      builder: (_) => const _CustomWaterSheet(),
    );
    if (ml != null && mounted) await _add(ml);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(localDayProvider); // rebuild at local midnight
    final now = ref.watch(clockProvider).now();
    final today = LocalDates.key(now);
    final logs = ref.watch(waterDayProvider(today));
    final week = ref.watch(waterWeekProvider(today));
    final profile = ref.watch(profileProvider).value;
    final goal = profile?.waterGoalMl ?? 0;
    final hud = context.hud;
    final t = Theme.of(context).textTheme;

    ref.listen<AsyncValue<List<WaterLog>>>(waterDayProvider(today), (
      prev,
      next,
    ) {
      final before = prev?.value;
      final after = next.value;
      if (before == null || after == null || goal <= 0) return;
      int sum(List<WaterLog> l) => l.fold(0, (a, w) => a + w.amountMl);
      if (sum(before) < goal && sum(after) >= goal) _pulse.arm(today);
    });
    _pulse.maybeFire(context, ref.read(settingsRepositoryProvider));

    return AppPage(
      title: 'Hydration',
      eyebrow: goal > 0
          ? 'GOAL ${Fmt.ml(goal).toUpperCase()} · SET BY YOU'
          : 'NO GOAL SET',
      children: [
        ...logs.when(
          loading: () => [const ScanlineLoader(height: 320, lines: 0)],
          error: (e, _) => [ErrorState(message: redactSecrets('$e'))],
          data: (list) {
            final h = HydrationSummary.fromAmounts(
              list.map((w) => w.amountMl),
              goal,
            );
            final label = !h.hasGoal
                ? 'No goal set'
                : h.remainingMl > 0
                ? '${preciseMl(h.remainingMl)} to go'
                : h.remainingMl == 0
                ? 'Goal reached'
                : 'Goal reached · +${Fmt.ml(-h.remainingMl)}';
            return [
              AppCard(
                accent: AppColors.water,
                brackets: true,
                child: Column(
                  children: [
                    CelebrationBurst(
                      controller: _pulse.burst,
                      color: AppColors.water,
                      spread: 1.1,
                      child: Hero(
                        tag: hydrationHeroTag,
                        child: LiquidReactor(
                          progress: h.visualProgress,
                          size: 230,
                          semanticLabel: 'Water today',
                          childAlignment: const Alignment(0, -0.45),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AnimatedTicker(
                                preciseMl(h.totalMl),
                                style: hud
                                    .number(size: 42)
                                    .copyWith(shadows: _legible),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'OF ${preciseMl(goal).toUpperCase()}',
                                style: hud
                                    .label(size: 11.5, color: hud.text)
                                    .copyWith(shadows: _legible),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      label,
                      style: t.titleSmall?.copyWith(
                        color: h.goalReached ? AppColors.success : null,
                      ),
                    ),
                    if (profile != null && h.hasGoal && !h.goalReached) ...[
                      const SizedBox(height: 4),
                      _PaceLine(
                        now: now,
                        totalMl: h.totalMl,
                        goalMl: goal,
                        wakeMinutes: profile.wakeMinutes,
                        sleepMinutes: profile.sleepMinutes,
                      ),
                    ],
                    const SizedBox(height: AppSpacing.lg),
                    Row(
                      children: [
                        for (final (ml, icon) in const [
                          (150, Icons.coffee_outlined),
                          (250, Icons.local_drink_outlined),
                          (500, Icons.water_drop_outlined),
                        ]) ...[
                          Expanded(
                            child: _AddTile(
                              icon: icon,
                              label: '+${Fmt.ml(ml)}',
                              onTap: () => _add(ml),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                        ],
                        Expanded(
                          child: _AddTile(
                            icon: Icons.tune_rounded,
                            label: 'Custom',
                            onTap: _custom,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SectionHeader('Today'),
              if (list.isEmpty)
                AppCard(
                  child: Row(
                    children: [
                      const GlowIcon(
                        Icons.water_drop_outlined,
                        color: AppColors.water,
                        framed: true,
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Text(
                          'No water logged today. One tap above adds a glass.',
                          style: t.bodyMedium?.copyWith(color: hud.textMuted),
                        ),
                      ),
                    ],
                  ),
                )
              else
                AppCard(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.sm,
                    AppSpacing.xs,
                    AppSpacing.sm,
                  ),
                  child: StaggeredList(
                    children: [
                      for (var i = 0; i < list.length; i++)
                        _SipRow(
                          log: list[i],
                          first: i == 0,
                          last: i == list.length - 1,
                        ),
                    ],
                  ),
                ),
            ];
          },
        ),
        const SectionHeader('Last 7 days', subtitle: 'Dashed line = goal'),
        AppCard(
          child: week.when(
            loading: () => const ScanlineLoader(height: 180, lines: 0),
            error: (e, _) => ErrorState(message: redactSecrets('$e')),
            data: (byDay) => _WeekChart(byDay: byDay, goal: goal),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        NoticeBanner(
          message:
              'Fluid needs vary with activity, climate, body size and '
              'health. Your goal (${Fmt.ml(goal)}) is set by you, not '
              'prescribed by the app.',
        ),
        const SizedBox(height: AppSpacing.md),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _Link(
                  icon: Icons.flag_outlined,
                  label: 'Edit goal',
                  onTap: () => context.push(AppPaths.profile),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _Link(
                  icon: Icons.notifications_outlined,
                  label: 'Reminder settings',
                  onTap: () => context.push(AppPaths.notificationSettings),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "On pace" vs a linear spread of the goal across the waking day.
class _PaceLine extends StatelessWidget {
  const _PaceLine({
    required this.now,
    required this.totalMl,
    required this.goalMl,
    required this.wakeMinutes,
    required this.sleepMinutes,
  });

  final DateTime now;
  final int totalMl;
  final int goalMl;
  final int wakeMinutes;
  final int sleepMinutes;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final span = sleepMinutes - wakeMinutes;
    if (span <= 60) return const SizedBox.shrink();
    final minute = now.hour * 60 + now.minute;
    final f = ((minute - wakeMinutes) / span).clamp(0.0, 1.0);
    final expected = (goalMl * f / 50).round() * 50;
    final behind = expected - totalMl;
    final text = f <= 0
        ? 'DAY STARTS AT ${_hm(wakeMinutes)}'
        : totalMl == 0
        ? 'START WITH A GLASS · ~${preciseMl(expected).toUpperCase()} BY NOW'
        : behind <= 100
        ? 'ON PACE · ${Fmt.ml(expected).toUpperCase()} EXPECTED BY NOW'
        : '${Fmt.ml(behind).toUpperCase()} BEHIND PACE';
    return Text(
      text,
      style: hud.mono(
        size: 10.5,
        color: behind > 100 && f > 0 && totalMl > 0
            ? (hud.isDark ? AppColors.warning : const Color(0xFF8A5300))
            : null,
      ),
      textAlign: TextAlign.center,
    );
  }

  static String _hm(int m) =>
      '${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}

class _AddTile extends StatelessWidget {
  const _AddTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        haptic: PressHaptic.none,
        pressedScale: 0.92,
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.water.withValues(alpha: 0.16),
                AppColors.water.withValues(alpha: 0.05),
              ],
            ),
            border: Border.all(color: AppColors.water.withValues(alpha: 0.4)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 22,
                color: hud.isDark ? AppColors.water : hud.accentInk,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: t.labelMedium?.copyWith(
                  color: hud.text,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SipRow extends ConsumerWidget {
  const _SipRow({required this.log, required this.first, required this.last});
  final WaterLog log;
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return Dismissible(
      key: ValueKey('water-${log.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: AppSpacing.lg),
        child: const Icon(Icons.delete_outline, color: AppColors.red),
      ),
      confirmDismiss: (_) async {
        await _delete(context, ref);
        return false;
      },
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 52,
              child: CustomPaint(
                painter: _RailPainter(
                  first: first,
                  last: last,
                  color: AppColors.water,
                  hud: hud,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            SizedBox(
              width: 76,
              child: Text(
                Fmt.time(log.loggedAt).toUpperCase(),
                style: hud.mono(size: 11),
              ),
            ),
            Expanded(child: Text(Fmt.ml(log.amountMl), style: t.titleSmall)),
            if (log.source != 'manual')
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.xs),
                child: Text(
                  log.source.toUpperCase(),
                  style: hud.label(size: 10),
                ),
              ),
            IconButton(
              tooltip: 'Delete ${Fmt.ml(log.amountMl)}',
              icon: Icon(Icons.close_rounded, size: 18, color: hud.textMuted),
              onPressed: () => _delete(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(waterRepositoryProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    Haptics.medium();
    await repo.remove(log.id);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Removed ${Fmt.ml(log.amountMl)}'),
          action: SnackBarAction(
            label: 'Undo',
            // WaterRepository has no restore; re-add the same amount at the
            // original time and source.
            onPressed: () =>
                repo.add(log.amountMl, at: log.loggedAt, source: log.source),
          ),
        ),
      );
  }
}

class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.first,
    required this.last,
    required this.color,
    required this.hud,
  });

  final bool first;
  final bool last;
  final Color color;
  final HudTheme hud;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final line = Paint()
      ..strokeWidth = 1.5
      ..color = color.withValues(alpha: 0.25);
    canvas.drawLine(
      Offset(cx, first ? cy : 0),
      Offset(cx, last ? cy : size.height),
      line,
    );
    canvas.drawCircle(
      Offset(cx, cy),
      7,
      Paint()
        ..color = color.withValues(alpha: 0.35 * hud.glowStrength)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawCircle(Offset(cx, cy), 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.first != first || old.last != last || old.hud != hud;
}

class _CustomWaterSheet extends StatefulWidget {
  const _CustomWaterSheet();

  @override
  State<_CustomWaterSheet> createState() => _CustomWaterSheetState();
}

class _CustomWaterSheetState extends State<_CustomWaterSheet> {
  final _ctrl = TextEditingController(text: '350');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  int? get _ml {
    final v = double.tryParse(_ctrl.text.trim().replaceAll(',', '.'));
    if (v == null || !v.isFinite) return null;
    final ml = v.round();
    return ml > 0 && ml <= 5000 ? ml : null;
  }

  @override
  Widget build(BuildContext context) {
    final ml = _ml;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AmountStepper(
          controller: _ctrl,
          unitLabel: 'ml · 1–5000',
          step: 50,
          max: 2000,
          valid: ml != null,
          onChanged: (v) => setState(() => _ctrl.text = plainNum(v)),
          onTyped: () => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.xl),
        HudButton(
          label: ml == null ? 'Add' : 'Add ${Fmt.ml(ml)}',
          icon: Icons.water_drop_rounded,
          expand: true,
          onPressed: ml == null ? null : () => Navigator.of(context).pop(ml),
        ),
      ],
    );
  }
}

class _Link extends StatelessWidget {
  const _Link({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      semanticLabel: label,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          GlowIcon(icon, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Icon(Icons.chevron_right, size: 18, color: context.hud.textMuted),
        ],
      ),
    );
  }
}

class _WeekChart extends StatelessWidget {
  const _WeekChart({required this.byDay, required this.goal});
  final Map<String, int> byDay;
  final int goal;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final keys = byDay.keys.toList()..sort();
    final maxVal = [
      ...byDay.values,
      goal,
    ].fold<int>(0, (a, b) => a > b ? a : b);
    final maxY = maxVal <= 0 ? 1000.0 : maxVal * 1.15;
    final logged = byDay.values.where((v) => v > 0).toList();
    final avg = logged.isEmpty
        ? 0
        : logged.reduce((a, b) => a + b) / logged.length;
    final hit = goal <= 0 ? 0 : byDay.values.where((v) => v >= goal).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Average',
                value: logged.isEmpty ? '—' : preciseMl(avg.round()),
                sub: logged.isEmpty
                    ? 'no logs yet'
                    : 'on ${logged.length} logged '
                          'day${logged.length == 1 ? '' : 's'}',
                color: AppColors.water,
              ),
            ),
            Expanded(
              child: StatTile(
                label: 'Goal hit',
                value: '$hit / 7',
                sub: 'days',
                color: AppColors.success,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        SizedBox(
          height: 170,
          child: Semantics(
            label:
                'Water per day: '
                '${keys.map((k) => '${DateFormat.E().format(LocalDates.parse(k))} ${Fmt.ml(byDay[k]!)}').join(', ')}',
            excludeSemantics: true,
            child: BarChart(
              BarChartData(
                maxY: maxY,
                minY: 0,
                gridData: HudChartStyle.grid(context),
                borderData: HudChartStyle.noBorder,
                barTouchData: HudChartStyle.barTouch(
                  context,
                  format: (g, rod) => Fmt.ml(rod.toY),
                ),
                extraLinesData: ExtraLinesData(
                  horizontalLines: [
                    if (goal > 0)
                      HorizontalLine(
                        y: goal.toDouble(),
                        color: AppColors.water.withValues(alpha: 0.7),
                        strokeWidth: 1,
                        dashArray: [4, 4],
                      ),
                  ],
                ),
                titlesData: HudChartStyle.titles(
                  context,
                  bottom: (v, meta) {
                    final i = v.toInt();
                    if (i < 0 || i >= keys.length) {
                      return const SizedBox.shrink();
                    }
                    return SideTitleWidget(
                      meta: meta,
                      child: Text(
                        DateFormat.E()
                            .format(LocalDates.parse(keys[i]))
                            .toUpperCase(),
                        style: HudChartStyle.axisLabel(context).copyWith(
                          color: i == keys.length - 1 ? hud.accentInk : null,
                        ),
                      ),
                    );
                  },
                ),
                barGroups: [
                  for (var i = 0; i < keys.length; i++)
                    BarChartGroupData(
                      x: i,
                      barRods: [
                        HudChartStyle.rod(
                          byDay[keys[i]]!.toDouble(),
                          goal > 0 && byDay[keys[i]]! >= goal
                              ? AppColors.water
                              : AppColors.water.withValues(alpha: 0.55),
                          width: 18,
                          backgroundMax: maxY,
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

const _legible = [Shadow(color: Color(0xB304060B), blurRadius: 8)];
