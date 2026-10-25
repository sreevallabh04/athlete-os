import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../app/boot/boot_sequence.dart';
import '../../core/domain/provenance.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/widgets.dart';

/// `/dev/gallery`: every HUD component and state on one page, for QA
/// screenshots and for screen engineers to copy from.
class DevGalleryScreen extends StatefulWidget {
  const DevGalleryScreen({super.key});

  @override
  State<DevGalleryScreen> createState() => _DevGalleryScreenState();
}

class _DevGalleryScreenState extends State<DevGalleryScreen>
    with SingleTickerProviderStateMixin {
  double _ring = 0.82;
  int _tick = 8432;
  bool _toggle = true;
  String _segment = 'week';
  OrbState _orb = OrbState.listening;
  final _chips = <String>{'Strength'};
  final _burst = CelebrationController();
  final _levels = StreamController<double>.broadcast();
  late final AnimationController _mic = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..addListener(_feedMic);
  int _staggerKey = 0;
  String _lastHaptic = '—';

  void _feedMic() {
    final t = _mic.value * 2 * math.pi;
    _levels.add(
      (0.5 + 0.35 * math.sin(t * 3) * math.cos(t * 7) + 0.15 * math.sin(t * 13))
          .clamp(0.0, 1.0),
    );
  }

  @override
  void initState() {
    super.initState();
    _mic.repeat();
    Haptics.debugOnEvent = (e) {
      if (mounted) setState(() => _lastHaptic = e);
    };
  }

  @override
  void dispose() {
    Haptics.debugOnEvent = null;
    _mic.dispose();
    _levels.close();
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return AppPage(
      title: 'HUD Gallery',
      eyebrow: 'DEV · DESIGN SYSTEM · v1',
      subtitle: 'Every component and state. Haptic log: $_lastHaptic',
      children: [
        // ── Brand ─────────────────────────────────────────────────────────
        const SectionHeader('Brand', subtitle: 'Emblem, palette, type'),
        AppCard(
          brackets: true,
          child: Row(
            children: [
              const AthleteEmblem(size: 96, detail: true),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Athlete OS', style: t.headlineSmall),
                    const SizedBox(height: 4),
                    Text(
                      'Segmented hex housing · faceted Λ · energy cell',
                      style: t.bodySmall,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text('SYS.ONLINE  21:47:09', style: hud.mono()),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final (name, c) in _palette) _Swatch(name: name, color: c),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Display 36', style: t.displaySmall),
              Text('Headline 28', style: t.headlineMedium),
              Text('Title 20 — Inter SemiBold', style: t.titleLarge),
              Text(
                'Body 14 — the quick brown fox, 1234567890',
                style: t.bodyMedium,
              ),
              Text('Label 12', style: t.labelMedium),
              const SizedBox(height: AppSpacing.sm),
              Text('HUD LABEL · RAJDHANI', style: hud.label(size: 13)),
              Text('128.4', style: hud.number(size: 44)),
              Text('mono › 00:42:17.031  HR 142', style: hud.mono(size: 12)),
            ],
          ),
        ),

        // ── Surfaces ──────────────────────────────────────────────────────
        const SectionHeader('Surfaces'),
        Row(
          children: [
            Expanded(
              child: AppCard(
                child: SizedBox(
                  height: 64,
                  child: Text('Default glass', style: t.titleSmall),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: AppCard(
                accent: AppColors.protein,
                child: SizedBox(
                  height: 64,
                  child: Text('Accent', style: t.titleSmall),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: AppCard(
                accent: AppColors.gold,
                glow: true,
                brackets: true,
                onTap: () {},
                child: SizedBox(
                  height: 64,
                  child: Text('Hero · tap me', style: t.titleSmall),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: HudFrame(
                ticks: true,
                tag: 'SYS·01',
                inset: 2,
                child: GlassPanel(
                  blur: 12,
                  child: SizedBox(
                    height: 64,
                    child: Text('GlassPanel + HudFrame', style: t.titleSmall),
                  ),
                ),
              ),
            ),
          ],
        ),

        // ── Data ──────────────────────────────────────────────────────────
        const SectionHeader('Data', subtitle: 'Rings, gauges, bars, tickers'),
        AppCard(
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  ProgressRing(
                    progress: _ring,
                    color: AppColors.cyan,
                    size: 140,
                    stroke: 11,
                    semanticLabel: 'Steps',
                    center: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedTicker(
                          '${(_ring * 100).round()}%',
                          style: hud.number(size: 30),
                        ),
                        Text('STEPS', style: hud.label(size: 10)),
                      ],
                    ),
                  ),
                  const ArcGauge(
                    value: 0.72,
                    valueText: '72',
                    label: 'READINESS',
                    color: AppColors.habit,
                    width: 150,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  HudButton.secondary(
                    label: 'Complete ring',
                    compact: true,
                    icon: Icons.flag_outlined,
                    onPressed: () => setState(() => _ring = 1.0),
                  ),
                  HudButton.ghost(
                    label: 'Reset',
                    compact: true,
                    onPressed: () => setState(() => _ring = 0.82),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: Column(
            children: spaced([
              const MetricBar(
                label: 'Protein',
                value: 112,
                target: 150,
                unit: ' g',
                color: AppColors.protein,
              ),
              const MetricBar(
                label: 'Carbs',
                value: 180,
                target: 240,
                unit: ' g',
                color: AppColors.carbs,
              ),
              const MetricBar(
                label: 'Water',
                value: 2.1,
                target: 3,
                unit: ' L',
                color: AppColors.water,
                segments: 0,
              ),
            ]),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: StatTile(
                      label: 'Steps',
                      value: _fmt(_tick),
                      sub: 'goal 10,000',
                      icon: Icons.directions_walk,
                      color: AppColors.steps,
                    ),
                  ),
                  const Expanded(
                    child: StatTile(
                      label: 'Resting HR',
                      value: '54 bpm',
                      sub: '−2 vs last week',
                      icon: Icons.favorite_outline,
                      color: AppColors.heart,
                    ),
                  ),
                  const Expanded(
                    child: StatTile(label: 'Sleep', value: '7h 42m'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              const HudSparkline(
                values: [6.2, 7.8, 5.9, 8.4, 9.1, 7.2, 10.4],
                color: AppColors.steps,
                semanticLabel: 'Steps trend',
              ),
              const SizedBox(height: AppSpacing.sm),
              HudButton.ghost(
                label: 'Roll the ticker',
                compact: true,
                icon: Icons.casino_outlined,
                onPressed: () =>
                    setState(() => _tick = 1000 + math.Random().nextInt(12000)),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: SizedBox(
            height: 170,
            child: LineChart(
              LineChartData(
                minY: 0,
                gridData: HudChartStyle.grid(context),
                borderData: HudChartStyle.noBorder,
                titlesData: HudChartStyle.titles(
                  context,
                  bottom: (v, m) => Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      const ['M', 'T', 'W', 'T', 'F', 'S', 'S'][v.toInt() % 7],
                      style: HudChartStyle.axisLabel(context),
                    ),
                  ),
                  bottomInterval: 1,
                ),
                lineTouchData: HudChartStyle.lineTouch(context, unit: ' kg'),
                lineBarsData: [
                  HudChartStyle.line(const [
                    FlSpot(0, 62),
                    FlSpot(1, 66),
                    FlSpot(2, 64),
                    FlSpot(3, 71),
                    FlSpot(4, 74),
                    FlSpot(5, 72),
                    FlSpot(6, 78),
                  ], AppColors.strength),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: SizedBox(
            height: 150,
            child: BarChart(
              BarChartData(
                gridData: HudChartStyle.grid(context),
                borderData: HudChartStyle.noBorder,
                titlesData: HudChartStyle.titles(context),
                barTouchData: HudChartStyle.barTouch(context, unit: ' kcal'),
                barGroups: [
                  for (var i = 0; i < 7; i++)
                    BarChartGroupData(
                      x: i,
                      barRods: [
                        HudChartStyle.rod(
                          1600 + 400 * math.sin(i * 1.3).abs(),
                          AppColors.calories,
                          backgroundMax: 2400,
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),

        // ── Controls ──────────────────────────────────────────────────────
        const SectionHeader('Controls'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: spaced([
              HudButton(
                label: 'Start workout',
                icon: Icons.play_arrow_rounded,
                expand: true,
                onPressed: () {},
              ),
              Row(
                children: [
                  Expanded(
                    child: HudButton.secondary(
                      label: 'Secondary',
                      expand: true,
                      onPressed: () {},
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: HudButton.ghost(
                      label: 'Ghost',
                      expand: true,
                      onPressed: () {},
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: HudButton(
                      label: 'Delete',
                      variant: HudButtonVariant.danger,
                      expand: true,
                      onPressed: () {},
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  const Expanded(
                    child: HudButton(
                      label: 'Syncing',
                      loading: true,
                      expand: true,
                      onPressed: null,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  const Expanded(
                    child: HudButton(
                      label: 'Disabled',
                      expand: true,
                      onPressed: null,
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final c in ['Strength', 'Running', 'Mobility'])
                    HudChip(
                      label: c,
                      selected: _chips.contains(c),
                      onTap: () => setState(
                        () => _chips.contains(c)
                            ? _chips.remove(c)
                            : _chips.add(c),
                      ),
                    ),
                  const HudChip(
                    label: 'Online',
                    dot: true,
                    color: AppColors.success,
                  ),
                  const HudChip(
                    label: 'PR',
                    icon: Icons.emoji_events_outlined,
                    color: AppColors.gold,
                    selected: true,
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(child: Text('Haptics', style: t.bodyLarge)),
                  HudToggle(
                    value: _toggle,
                    semanticLabel: 'Haptics',
                    onChanged: (v) => setState(() => _toggle = v),
                  ),
                ],
              ),
              SegmentedHud<String>(
                value: _segment,
                onChanged: (v) => setState(() => _segment = v),
                segments: const [
                  HudSegment(value: 'day', label: 'Day'),
                  HudSegment(value: 'week', label: 'Week'),
                  HudSegment(value: 'month', label: 'Month'),
                ],
              ),
              const TextField(
                decoration: InputDecoration(
                  labelText: 'Search foods',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  FilledButton(onPressed: () {}, child: const Text('Filled')),
                  OutlinedButton(
                    onPressed: () {},
                    child: const Text('Outlined'),
                  ),
                  TextButton(onPressed: () {}, child: const Text('Text')),
                  Switch(
                    value: _toggle,
                    onChanged: (v) => setState(() => _toggle = v),
                  ),
                ],
              ),
            ]),
          ),
        ),

        // ── Motion ────────────────────────────────────────────────────────
        const SectionHeader('Motion'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StaggeredList(
                key: ValueKey(_staggerKey),
                gap: AppSpacing.sm,
                children: [
                  for (var i = 0; i < 4; i++)
                    PressableScale(
                      onTap: () {},
                      child: GlassPanel(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Row(
                          children: [
                            GlowIcon(
                              const [
                                Icons.bolt,
                                Icons.water_drop_outlined,
                                Icons.bedtime_outlined,
                                Icons.local_fire_department_outlined,
                              ][i],
                              framed: true,
                              size: 16,
                            ),
                            const SizedBox(width: AppSpacing.md),
                            Text('Staggered item ${i + 1}', style: t.bodyLarge),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  HudButton.secondary(
                    label: 'Replay stagger',
                    compact: true,
                    onPressed: () => setState(() => _staggerKey++),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  CelebrationBurst(
                    controller: _burst,
                    color: AppColors.gold,
                    haptic: true,
                    spread: 1.4,
                    child: HudButton(
                      label: 'Celebrate',
                      compact: true,
                      icon: Icons.auto_awesome,
                      onPressed: _burst.fire,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // ── AI ────────────────────────────────────────────────────────────
        const SectionHeader('Assistant', subtitle: 'JarvisOrb states'),
        AppCard(
          child: Column(
            children: [
              Center(
                child: JarvisOrb(state: _orb, size: 180, level: _levels.stream),
              ),
              const SizedBox(height: AppSpacing.md),
              SegmentedHud<OrbState>(
                value: _orb,
                onChanged: (v) => setState(() => _orb = v),
                segments: const [
                  HudSegment(value: OrbState.idle, label: 'Idle'),
                  HudSegment(value: OrbState.listening, label: 'Listen'),
                  HudSegment(value: OrbState.thinking, label: 'Think'),
                  HudSegment(value: OrbState.speaking, label: 'Speak'),
                ],
              ),
            ],
          ),
        ),

        // ── States ────────────────────────────────────────────────────────
        const SectionHeader('States'),
        const AppCard(
          child: EmptyState(
            icon: Icons.restaurant_outlined,
            eyebrow: 'STANDBY',
            title: 'No meals logged yet',
            message: 'Snap a photo or search a food to start today’s tally.',
            actionLabel: 'Log a meal',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: ErrorState(
            message: 'Health Connect didn’t respond. Your data is safe.',
            onRetry: () {},
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        const AppCard(
          child: Column(
            children: [
              LoadingState(label: 'SYNCING WORKOUTS…'),
              ScanlineLoader(lines: 3),
              SizedBox(height: AppSpacing.md),
              ScanlineLoader(height: 90, lines: 0),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        ...spaced([
          const NoticeBanner(
            message: 'Showing sample data until Health Connect is linked.',
          ),
          NoticeBanner(
            message: 'Steps are 3 h old.',
            icon: Icons.schedule,
            color: AppColors.warning,
            actionLabel: 'Sync',
            onAction: () {},
          ),
          const NoticeBanner(
            message: 'AI budget reached for today.',
            icon: Icons.block,
            color: AppColors.red,
          ),
        ]),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            SourceBadge(
              origin: DataOrigin.values.first,
              asOf: DateTime.now().subtract(const Duration(minutes: 12)),
            ),
            SourceBadge(origin: DataOrigin.values.first, isEstimate: true),
            SourceBadge(
              origin: DataOrigin.values.first,
              asOf: DateTime.now().subtract(const Duration(hours: 5)),
            ),
          ],
        ),

        // ── Overlays ──────────────────────────────────────────────────────
        const SectionHeader('Overlays & haptics'),
        AppCard(
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              HudButton.secondary(
                label: 'Bottom sheet',
                compact: true,
                onPressed: () => showHudBottomSheet<void>(
                  context,
                  title: 'Log water',
                  builder: (context) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'A frosted HUD sheet on a gentle spring.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      HudButton(
                        label: 'Add 250 ml',
                        expand: true,
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
              ),
              HudButton.secondary(
                label: 'Boot sequence',
                compact: true,
                onPressed: () =>
                    Navigator.of(context, rootNavigator: true).push(
                      MaterialPageRoute<void>(
                        fullscreenDialog: true,
                        builder: (_) => const _BootPreview(),
                      ),
                    ),
              ),
              for (final (name, fn) in <(String, VoidCallback)>[
                ('selection', Haptics.selection),
                ('light', Haptics.light),
                ('medium', Haptics.medium),
                ('heavy', Haptics.heavy),
                ('success', Haptics.success),
                ('warning', Haptics.warning),
                ('goal', Haptics.goalReached),
              ])
                HudChip(label: name, onTap: fn, icon: Icons.vibration),
            ],
          ),
        ),
      ],
    );
  }

  static String _fmt(int v) {
    final s = v.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  static const _palette = <(String, Color)>[
    ('cyan', AppColors.cyan),
    ('gold', AppColors.gold),
    ('red', AppColors.red),
    ('calories', AppColors.calories),
    ('protein', AppColors.protein),
    ('carbs', AppColors.carbs),
    ('fat', AppColors.fat),
    ('fiber', AppColors.fiber),
    ('water', AppColors.water),
    ('steps', AppColors.steps),
    ('heart', AppColors.heart),
    ('sleep', AppColors.sleep),
    ('strength', AppColors.strength),
    ('running', AppColors.running),
    ('mood', AppColors.mood),
    ('habit', AppColors.habit),
    ('competition', AppColors.competition),
    ('success', AppColors.success),
    ('warning', AppColors.warning),
  ];
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.name, required this.color});
  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final hex = color.toARGB32().toRadixString(16).substring(2).toUpperCase();
    return SizedBox(
      width: 92,
      child: Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: hud.mono(size: 10, color: hud.text),
                  maxLines: 1,
                ),
                Text('#$hex', style: hud.mono(size: 9)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Loops the boot sequence visuals (tap to close).
class _BootPreview extends StatefulWidget {
  const _BootPreview();

  @override
  State<_BootPreview> createState() => _BootPreviewState();
}

class _BootPreviewState extends State<_BootPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => Navigator.pop(context),
    child: BootSequenceView(progress: _c),
  );
}
