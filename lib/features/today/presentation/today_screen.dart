import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/paths.dart';
import '../../../core/contracts/calendar_reader.dart';
import '../../../core/domain/provenance.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../onboarding/application/persona_providers.dart';
import '../../onboarding/presentation/persona_cards.dart';
import '../../planning/application/planning_providers.dart';
import '../application/today_providers.dart';
import '../data/today_repository.dart';
import '../domain/daily_summary.dart';
import '../domain/today_layout.dart';
import 'widgets/briefing.dart';
import 'widgets/deck.dart';
import 'widgets/deck_cards.dart';
import 'widgets/quick_actions.dart';
import 'widgets/target_reactor.dart';

/// The JARVIS command deck: greeting, honest system status, the daily
/// targets reactor, one-tap logging and the day's plan, ordered for the
/// time of day.
class TodayScreen extends ConsumerStatefulWidget {
  const TodayScreen({super.key});

  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends ConsumerState<TodayScreen> {
  final _entrances = EntranceCoordinator();
  bool _scanning = false;
  bool _scrolled = false;

  Future<void> _refresh(String date) async {
    Haptics.medium();
    setState(() => _scanning = true);
    ref.invalidate(todaySnapshotProvider);
    ref.invalidate(calendarDayProvider(date));
    try {
      await Future.wait([
        ref.read(todaySnapshotProvider.future),
        Future<void>.delayed(const Duration(milliseconds: 900)),
      ]);
      Haptics.light();
    } catch (_) {
      Haptics.warning();
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(clockProvider).now();
    final date = LocalDates.key(now);
    final snapshot = ref.watch(todaySnapshotProvider);
    final calendar = ref.watch(calendarDayProvider(date));
    final statuses = ref.watch(integrationStatusesProvider).value;
    final mq = MediaQuery.of(context);
    final reduced = AppMotion.reduced(context);

    final body = snapshot.when(
      loading: () => const _DeckSkeleton(),
      error: (e, _) => ErrorState(
        message: 'Could not load today’s data.',
        onRetry: () => ref.invalidate(todaySnapshotProvider),
      ),
      data: (s) => _Deck(snapshot: s, calendar: calendar),
    );

    final scroll = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _DeckBarDelegate(
            topPadding: mq.padding.top,
            hud: context.hud,
            statuses: statuses,
            scrolled: _scrolled,
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.xs,
            AppSpacing.gutter,
            mq.padding.bottom + AppSpacing.xxxl,
          ),
          sliver: SliverList.list(
            children: [
              _Greeting(
                now: now,
                name: snapshot.value?.profile.displayName,
                reduced: reduced,
              ),
              const SizedBox(height: AppSpacing.lg),
              body,
            ],
          ),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: EntranceScope(
        coordinator: _entrances,
        child: Stack(
          children: [
            NotificationListener<ScrollUpdateNotification>(
              onNotification: (n) {
                final scrolled = n.metrics.pixels > 4;
                if (n.depth == 0 && scrolled != _scrolled) {
                  setState(() => _scrolled = scrolled);
                }
                return false;
              },
              child: RefreshIndicator.noSpinner(
                onRefresh: () => _refresh(date),
                child: scroll,
              ),
            ),
            Positioned(
              top: mq.padding.top + _DeckBarDelegate.barHeight,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: _ScanBeam(active: _scanning, reduced: reduced),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────── Header

class _DeckBarDelegate extends SliverPersistentHeaderDelegate {
  _DeckBarDelegate({
    required this.topPadding,
    required this.hud,
    required this.statuses,
    required this.scrolled,
  });

  static const barHeight = 52.0;
  final double topPadding;
  final HudTheme hud;
  final List<IntegrationConnection>? statuses;
  final bool scrolled;

  @override
  double get minExtent => topPadding + barHeight;
  @override
  double get maxExtent => topPadding + barHeight;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: overlaps || scrolled ? 1 : 0),
      duration: AppMotion.medium,
      builder: (context, g, child) {
        Widget bg = Container(
          decoration: BoxDecoration(
            color: hud.glassFillStrong.withValues(
              alpha: hud.glassFillStrong.a * g,
            ),
            border: Border(
              bottom: BorderSide(
                color: hud.hairline.withValues(alpha: 0.14 * g),
              ),
            ),
          ),
        );
        if (g > 0.01) {
          bg = ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 18 * g, sigmaY: 18 * g),
              child: bg,
            ),
          );
        }
        return Stack(fit: StackFit.expand, children: [bg, child!]);
      },
      child: Padding(
        padding: EdgeInsets.only(
          top: topPadding,
          left: AppSpacing.gutter - 4,
          right: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Expanded(child: SystemStatusRow(statuses: statuses)),
            IconButton(
              tooltip: 'Plan your day',
              icon: const Icon(Icons.view_timeline_outlined),
              onPressed: () {
                Haptics.light();
                context.push(AppPaths.planner);
              },
            ),
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () {
                Haptics.light();
                context.push(AppPaths.settings);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_DeckBarDelegate old) =>
      old.topPadding != topPadding ||
      old.hud != hud ||
      old.scrolled != scrolled ||
      old.statuses != statuses;
}

/// Honest system glyphs: Health Connect, AI core and calendar. Never shows
/// "online" unless the integration really reported connected.
class SystemStatusRow extends StatelessWidget {
  const SystemStatusRow({super.key, required this.statuses});
  final List<IntegrationConnection>? statuses;

  (Color, String) _state(BuildContext context, String id) {
    final hud = context.hud;
    if (statuses == null) return (hud.textMuted, 'checking');
    final s = statuses!.where((r) => r.provider == id).firstOrNull?.status;
    return switch (s) {
      ConnectionStates.connected => (AppColors.success, 'online'),
      ConnectionStates.needsSetup => (AppColors.warning, 'needs setup'),
      ConnectionStates.awaitingCredentials => (
        AppColors.warning,
        'awaiting keys',
      ),
      ConnectionStates.error => (AppColors.red, 'error'),
      _ => (hud.textMuted.withValues(alpha: 0.55), 'offline'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final items = [
      ('HEALTH', 'Health Connect', Providers.healthConnect),
      ('AI', 'AI core', Providers.aiBackend),
      ('CAL', 'Calendar', Providers.googleCalendar),
    ];
    final states = [for (final i in items) _state(context, i.$3)];
    final label = [
      for (var i = 0; i < items.length; i++) '${items[i].$2} ${states[i].$2}',
    ].join(', ');
    return Semantics(
      button: true,
      label: 'System status: $label. Open integrations.',
      excludeSemantics: true,
      child: PressableScale(
        onTap: () => context.push(AppPaths.integrations),
        pressedScale: 0.97,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(width: AppSpacing.md),
                StatusDot(color: states[i].$1, size: 5),
                const SizedBox(width: 5),
                Text(
                  items[i].$1,
                  style: hud.mono(size: 10, color: hud.textMuted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({
    required this.now,
    required this.name,
    required this.reduced,
  });

  final DateTime now;
  final String? name;
  final bool reduced;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return Entrance(
      enabled: !reduced,
      blur: 6,
      offset: const Offset(0, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${DateFormat('EEEE d MMMM').format(now).toUpperCase()} · '
            '${DateFormat('HH:mm').format(now)}',
            style: hud.mono(size: 10.5, color: hud.accentInk),
          ),
          const SizedBox(height: 6),
          Semantics(
            header: true,
            child: Text(
              greetingFor(now, name),
              style: t.headlineSmall?.copyWith(fontSize: 25),
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pull-to-refresh "sensor rescan": a cyan beam sweeping under the bar.
class _ScanBeam extends StatefulWidget {
  const _ScanBeam({required this.active, required this.reduced});
  final bool active;
  final bool reduced;

  @override
  State<_ScanBeam> createState() => _ScanBeamState();
}

class _ScanBeamState extends State<_ScanBeam>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didUpdateWidget(_ScanBeam old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active && !widget.reduced) {
      _c.repeat();
    } else if (!widget.active && old.active) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return AnimatedOpacity(
      duration: AppMotion.short,
      opacity: widget.active ? 1 : 0,
      child: SizedBox(
        height: 120,
        child: Stack(
          children: [
            AnimatedBuilder(
              animation: _c,
              builder: (context, _) => CustomPaint(
                size: const Size(double.infinity, 120),
                painter: _BeamPainter(
                  t: widget.reduced ? 0.5 : _c.value,
                  color: hud.accent,
                  glow: hud.glowStrength,
                ),
              ),
            ),
            Positioned(
              top: 6,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  'RESCANNING SENSORS',
                  style: hud.mono(size: 10, color: hud.accentInk),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BeamPainter extends CustomPainter {
  _BeamPainter({required this.t, required this.color, required this.glow});
  final double t;
  final Color color;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final y = 22 + (size.height - 30) * Curves.easeInOut.transform(t);
    final rect = Rect.fromLTWH(0, y - 18, size.width, 18);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0), color.withValues(alpha: 0.18)],
        ).createShader(rect),
    );
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: 0.9),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(0, y, size.width, 1))
        ..maskFilter = MaskFilter.blur(BlurStyle.solid, 2 * glow),
    );
  }

  @override
  bool shouldRepaint(_BeamPainter old) => old.t != t || old.color != color;
}

// ───────────────────────────────────────────────────────────── Deck body

class _DeckSkeleton extends StatelessWidget {
  const _DeckSkeleton();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ScanlineLoader(height: 64, lines: 0),
      SizedBox(height: AppSpacing.md),
      ScanlineLoader(height: 240, lines: 0),
      SizedBox(height: AppSpacing.md),
      ScanlineLoader(lines: 3),
    ],
  );
}

class _Deck extends ConsumerWidget {
  const _Deck({required this.snapshot, required this.calendar});
  final TodaySnapshot snapshot;
  final AsyncValue<CalendarReadResult> calendar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = snapshot;
    final phase = dayPhaseOf(s.now);
    final summary = buildDailySummary(
      summaryInputFor(
        s,
        calendar.value,
        pending: calendar.isLoading && !calendar.hasValue,
      ),
    );
    final session = ref.watch(todaysPlannedSessionProvider).value;
    final order = todaySectionOrder(s.now, sessionDone: s.workoutToday != null);

    Widget section(TodaySection id) => switch (id) {
      TodaySection.briefing => Entrance(
        child: BriefingStrip(summary: summary, phase: phase, now: s.now),
      ),
      TodaySection.targets => TargetReactor(rings: targetRings(context, s)),
      TodaySection.quickActions => Entrance(
        delay: const Duration(milliseconds: 90),
        child: QuickActionsRow(
          waterMl: s.waterMl,
          waterGoalMl: s.profile.waterGoalMl,
          moodLogged: s.moodToday != null,
          sessionTitle: session?.day.title,
        ),
      ),
      TodaySection.session => TodaySessionCard(
        loggedTitle: s.workoutToday?.title,
        emphasize: phase == DayPhase.morning,
      ),
      TodaySection.routine => const RoutinePeekCard(),
      TodaySection.priorities => PrioritiesCard(snapshot: s),
      TodaySection.agenda => AgendaCard(calendar: calendar, now: s.now),
      TodaySection.habits => const HabitsCard(),
      TodaySection.review => ReviewCard(
        snapshot: s,
        evening: phase == DayPhase.evening,
      ),
      TodaySection.vitals => VitalsCard(snapshot: s),
      TodaySection.competition => CompetitionModule(
        view: s.competition,
        name: s.profile.displayName,
      ),
      TodaySection.inbox => const InboxTeaser(),
    };

    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < 900) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: spaced([for (final id in order) section(id)]),
          );
        }
        final left = <Widget>[];
        final right = <Widget>[];
        for (var i = 0; i < order.length; i++) {
          (i.isEven ? left : right).add(section(order[i]));
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: spaced(left),
              ),
            ),
            const SizedBox(width: AppSpacing.xl),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: spaced(right),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// "12k", "10k", "12.5k".
String _kSteps(int v) {
  final k = v / 1000;
  return k == k.roundToDouble() ? '${k.round()}k' : '${k.toStringAsFixed(1)}k';
}

String _litres(int ml) {
  final l = (ml / 1000).toStringAsFixed(2);
  return l.replaceAll(RegExp(r'\.?0+$'), '');
}

/// The four reactor rings built from the snapshot. Targets are real
/// configuration; values are only what was logged or synced.
List<TargetRingData> targetRings(BuildContext context, TodaySnapshot s) {
  final p = s.profile;
  final n = s.nutrition;
  final logged = n.entries > 0;
  final steps = s.steps;
  final stepsLeft = steps == null ? 0 : p.stepGoal - steps.value.round();
  final kcalLeft = p.calorieTarget - n.kcal;
  final proteinToGo = (p.proteinTargetG - n.proteinG).round();
  final waterLeft = p.waterGoalMl - s.waterMl;
  final t = Theme.of(context).textTheme;
  final hud = context.hud;
  Widget actions(List<Widget> buttons) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.md),
    child: Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: buttons,
    ),
  );
  Text muted(String text) =>
      Text(text, style: t.bodySmall?.copyWith(color: hud.textMuted));

  return [
    TargetRingData(
      id: 'steps',
      label: 'STEPS',
      unit: 'STEPS',
      color: AppColors.steps,
      icon: Icons.directions_walk,
      value: steps?.value,
      target: p.stepGoal.toDouble(),
      valueText: steps == null ? '—' : Fmt.integer(steps.value),
      targetText: _kSteps(p.stepGoal),
      statusText: stepsLeft > 0
          ? '${Fmt.integer(stepsLeft)} to go'
          : 'Goal reached',
      detail: steps == null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Steps arrive when Health Connect syncs.'),
                muted(
                  'Target ${Fmt.integer(p.stepGoal)}. Nothing is estimated '
                  'in the meantime.',
                ),
                actions([
                  HudButton.secondary(
                    label: 'Check Health Connect',
                    compact: true,
                    onPressed: () => context.push(AppPaths.healthStatus),
                  ),
                ]),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                        if (s.distance != null) Fmt.km(s.distance!.value),
                        if (s.activeMinutes != null)
                          '${s.activeMinutes!.value.round()} active min',
                      ]
                      .join(' · ')
                      .ifEmpty('Distance and active minutes not synced.'),
                ),
                const SizedBox(height: AppSpacing.sm),
                SourceBadge(
                  origin: DataOrigin.fromKey(steps.origin),
                  asOf: steps.computedAt,
                  now: s.now,
                ),
                actions([
                  HudButton.secondary(
                    label: 'Steps detail',
                    compact: true,
                    onPressed: () => context.push(AppPaths.steps),
                  ),
                ]),
              ],
            ),
    ),
    TargetRingData(
      id: 'kcal',
      label: 'CALORIES',
      unit: 'KCAL',
      color: AppColors.calories,
      icon: Icons.local_fire_department_outlined,
      value: logged ? n.kcal : null,
      target: p.calorieTarget.toDouble(),
      valueText: Fmt.integer(n.kcal),
      targetText: Fmt.integer(p.calorieTarget),
      missingText: 'NOT LOGGED',
      statusText: kcalLeft >= 0
          ? '${Fmt.integer(kcalLeft)} left'
          : '${Fmt.integer(-kcalLeft)} over',
      detail: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (logged) ...[
            Text(
              '${s.mealsLogged} meal${s.mealsLogged == 1 ? '' : 's'} · '
              '${n.entries} item${n.entries == 1 ? '' : 's'}'
              '${s.nutritionLastLoggedAt == null ? '' : ' · last ${Fmt.ago(s.nutritionLastLoggedAt!, s.now)}'}',
            ),
            const SizedBox(height: AppSpacing.md),
            MetricBar(
              label: 'Carbs',
              value: n.carbsG,
              target: p.carbsTargetG,
              color: AppColors.carbs,
              unit: ' g',
            ),
            const SizedBox(height: AppSpacing.sm),
            MetricBar(
              label: 'Fat',
              value: n.fatG,
              target: p.fatTargetG,
              color: AppColors.fat,
              unit: ' g',
            ),
          ] else
            Text(
              'Target ${Fmt.kcal(p.calorieTarget)} · '
              '${p.proteinTargetG.round()} P · ${p.carbsTargetG.round()} C · '
              '${p.fatTargetG.round()} F.',
            ),
          actions([
            HudButton.secondary(
              label: 'Log meal',
              icon: Icons.add,
              compact: true,
              onPressed: () => context.push(AppPaths.addFood),
            ),
            HudButton.ghost(
              label: 'Nutrition',
              compact: true,
              onPressed: () => context.go(AppPaths.nutrition),
            ),
          ]),
        ],
      ),
    ),
    TargetRingData(
      id: 'protein',
      label: 'PROTEIN',
      unit: 'G PROTEIN',
      color: AppColors.protein,
      icon: Icons.egg_alt_outlined,
      value: logged ? n.proteinG : null,
      target: p.proteinTargetG,
      valueText: Fmt.integer(n.proteinG),
      targetText: '${p.proteinTargetG.round()} g',
      missingText: 'NOT LOGGED',
      statusText: proteinToGo > 0 ? '$proteinToGo g to go' : 'Target met',
      detail: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            logged
                ? '${Fmt.integer(n.proteinG)} g of ${p.proteinTargetG.round()} g '
                      'from your food log.'
                : 'Target ${p.proteinTargetG.round()} g, spread across your '
                      'meals.',
          ),
          actions([
            HudButton.secondary(
              label: 'Log meal',
              icon: Icons.add,
              compact: true,
              onPressed: () => context.push(AppPaths.addFood),
            ),
          ]),
        ],
      ),
    ),
    TargetRingData(
      id: 'water',
      label: 'WATER',
      unit: 'LITRES',
      color: AppColors.water,
      icon: Icons.water_drop_outlined,
      value: s.waterMl > 0 ? s.waterMl.toDouble() : null,
      target: p.waterGoalMl.toDouble(),
      valueText: _litres(s.waterMl),
      targetText: Fmt.ml(p.waterGoalMl),
      missingText: 'NOT LOGGED',
      statusText: waterLeft > 0 ? '${Fmt.ml(waterLeft)} to go' : 'Goal reached',
      detail: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.waterLastLoggedAt == null
                ? 'No water logged today. One tap on +250 ml below.'
                : 'Last logged ${Fmt.ago(s.waterLastLoggedAt!, s.now)}.',
          ),
          actions([
            HudButton.secondary(
              label: 'Hydration',
              compact: true,
              onPressed: () => context.push(AppPaths.hydration),
            ),
          ]),
        ],
      ),
    ),
  ];
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

/// Facts for the deterministic briefing. Public for tests.
SummaryInput summaryInputFor(
  TodaySnapshot s,
  CalendarReadResult? cal, {
  bool pending = false,
}) {
  final p = s.profile;
  return SummaryInput(
    now: s.now,
    competitionHeadline: s.competition?.countdown.headline(
      s.competition!.competition.name,
    ),
    steps: s.steps == null
        ? null
        : StepsFact(
            steps: s.steps!.value.round(),
            goal: p.stepGoal,
            origin: s.steps!.origin,
            asOf: s.steps!.computedAt,
          ),
    nutrition: NutritionFact(
      entries: s.nutrition.entries,
      kcal: s.nutrition.kcal,
      proteinG: s.nutrition.proteinG,
      kcalTarget: p.calorieTarget,
      proteinTargetG: p.proteinTargetG,
    ),
    water: WaterFact(ml: s.waterMl, goalMl: p.waterGoalMl),
    calendarPending: pending,
    calendar: cal == null
        ? null
        : CalendarFact(
            connected: cal.connected,
            error: cal.error,
            events: [
              for (final e in cal.events)
                EventFact(title: e.title, start: e.start, allDay: e.allDay),
            ],
          ),
    plannedWorkout: s.plannedWorkout,
    completedWorkout: s.workoutToday == null
        ? null
        : (s.workoutToday!.title, s.workoutToday!.source),
    sleep: s.sleep == null
        ? null
        : SleepFact(
            minutes: s.sleep!.value.round(),
            origin: s.sleep!.origin,
            asOf: s.sleep!.computedAt,
          ),
  );
}
