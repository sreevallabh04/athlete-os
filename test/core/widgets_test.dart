import 'dart:async';

import 'package:athlete_os/core/domain/provenance.dart';
import 'package:athlete_os/core/theme/app_theme.dart';
import 'package:athlete_os/core/theme/tokens.dart';
import 'package:athlete_os/core/widgets/widgets.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(
  Widget child, {
  bool light = false,
  double textScale = 1,
  bool scroll = true,
}) => MaterialApp(
  theme: light ? AppTheme.light() : AppTheme.dark(),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: scroll
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: child,
              )
            : child,
      ),
    ),
  ),
);

Future<void> _settle(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 1500));

void main() {
  tearDown(() => Haptics.debugOnEvent = null);

  testWidgets('AppCard: glass, accent, brackets, glow, tap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            const AppCard(child: Text('Plain')),
            AppCard(
              accent: AppColors.protein,
              brackets: true,
              glow: true,
              semanticLabel: 'Protein card',
              onTap: () => taps++,
              child: const Text('Accent'),
            ),
            const AppCard(
              gradient: AppGradients.brand,
              child: Text('Gradient'),
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('Accent'));
    await _settle(tester);
    expect(taps, 1);
    expect(find.bySemanticsLabel(RegExp('Protein card')), findsOneWidget);
  });

  testWidgets('AppCard keeps ink from inner ListTiles visible', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        AppCard(
          child: ListTile(title: const Text('Row'), onTap: () => taps++),
        ),
      ),
    );
    await tester.tap(find.text('Row'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(taps, 1);
  });

  testWidgets('AppPage: large title, actions, back button, cascade', (
    tester,
  ) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        navigatorKey: nav,
        home: AppPage(
          title: 'Root',
          eyebrow: 'SUN 25 OCT',
          subtitle: 'Sub',
          actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.add))],
          onRefresh: () async {},
          children: [
            for (var i = 0; i < 12; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: AppCard(child: SizedBox(height: 80, child: Text('C$i'))),
              ),
          ],
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('Root'), findsWidgets);
    expect(find.text('SUN 25 OCT'), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
    // Collapse the header.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await _settle(tester);
    expect(find.text('Root'), findsWidgets);

    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const AppPage(title: 'Child', children: [Text('x')]),
      ),
    );
    await tester.pump(); // first frame of a push is built offstage
    await _settle(tester);
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('ProgressRing animates and celebrates when a goal completes', (
    tester,
  ) async {
    final events = <String>[];
    Haptics.debugOnEvent = events.add;
    Widget ring(double p) => _app(
      ProgressRing(
        progress: p,
        color: AppColors.steps,
        semanticLabel: 'Steps',
        center: const Text('center'),
      ),
    );
    await tester.pumpWidget(ring(0.6));
    await _settle(tester);
    expect(find.text('center'), findsOneWidget);
    expect(events, isEmpty);
    await tester.pumpWidget(ring(1.2));
    await tester.pump(const Duration(milliseconds: 900));
    await _settle(tester);
    expect(events, contains('goalReached'));
    // Non-finite progress is safe.
    await tester.pumpWidget(ring(double.nan));
    await _settle(tester);
  });

  testWidgets('MetricBar, StatTile, SourceBadge, SectionHeader render', (
    tester,
  ) async {
    final now = DateTime(2026, 10, 25, 12);
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            const SectionHeader('Fitness', subtitle: 'Today', action: 'All'),
            const MetricBar(
              label: 'Protein',
              value: 92,
              target: 150,
              color: AppColors.protein,
              unit: ' g',
            ),
            const MetricBar(
              label: 'Zero',
              value: 0,
              target: 0,
              color: AppColors.carbs,
              segments: 0,
            ),
            const StatTile(label: 'Steps', value: '8,432', sub: 'goal 10k'),
            const StatTile(
              label: 'HR',
              value: '54 bpm',
              icon: Icons.favorite,
              color: AppColors.heart,
            ),
            SourceBadge(
              origin: DataOrigin.values.first,
              asOf: now.subtract(const Duration(minutes: 5)),
              now: now,
            ),
            SourceBadge(
              origin: DataOrigin.values.first,
              asOf: now.subtract(const Duration(hours: 6)),
              now: now,
            ),
            SourceBadge(origin: DataOrigin.values.first, isEstimate: true),
          ],
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('Fitness'), findsOneWidget);
    expect(find.text('8,432'), findsOneWidget);
    expect(find.text('54 bpm'), findsOneWidget);
    expect(find.textContaining('stale'), findsOneWidget);
  });

  testWidgets('Empty, error, loading states and notices', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            const EmptyState(
              icon: Icons.inbox,
              title: 'Nothing here',
              message: 'Add something',
              eyebrow: 'STANDBY',
              actionLabel: 'Add',
            ),
            const EmptyState(
              icon: Icons.inbox,
              title: 'Compact',
              compact: true,
            ),
            ErrorState(message: 'Boom', onRetry: () => retried++),
            const LoadingState(),
            const LoadingState(label: 'SYNCING', compact: true),
            const ScanlineLoader(),
            const ScanlineLoader(height: 60, lines: 0),
            NoticeBanner(
              message: 'Heads up',
              actionLabel: 'Fix',
              onAction: () {},
            ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('SYSTEM FAULT'), findsOneWidget);
    await tester.ensureVisible(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(retried, 1);
    expect(find.text('Heads up'), findsOneWidget);
  });

  testWidgets('Controls: button, chip, toggle, segmented', (tester) async {
    var pressed = 0;
    var toggled = false;
    var segment = 'a';
    var chip = 0;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => Column(
            children: [
              HudButton(
                label: 'Go',
                onPressed: () => pressed++,
                icon: Icons.play_arrow,
              ),
              HudButton.secondary(label: 'Second', onPressed: () => pressed++),
              HudButton.ghost(label: 'Ghost', onPressed: () => pressed++),
              const HudButton(label: 'Off', onPressed: null),
              const HudButton(label: 'Busy', onPressed: null, loading: true),
              HudChip(label: 'Chip', onTap: () => chip++),
              const HudChip(label: 'Dot', dot: true),
              HudToggle(
                value: toggled,
                semanticLabel: 'Toggle',
                onChanged: (v) => setState(() => toggled = v),
              ),
              SegmentedHud<String>(
                value: segment,
                onChanged: (v) => setState(() => segment = v),
                segments: const [
                  HudSegment(value: 'a', label: 'Alpha'),
                  HudSegment(value: 'b', label: 'Beta', icon: Icons.star),
                ],
              ),
              const GlowIcon(Icons.bolt, framed: true),
              const GlowIcon(Icons.bolt),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.tap(find.text('Second'));
    await tester.tap(find.text('Ghost'));
    await tester.tap(find.text('Off'), warnIfMissed: false);
    await tester.tap(find.text('CHIP'));
    await tester.tap(find.bySemanticsLabel('Toggle'));
    await tester.tap(find.text('Beta'));
    await _settle(tester);
    expect(pressed, 3);
    expect(chip, 1);
    expect(toggled, isTrue);
    expect(segment, 'b');
  });

  testWidgets('HUD bottom sheet opens and closes', (tester) async {
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => HudButton(
            label: 'Open',
            onPressed: () => showHudBottomSheet<void>(
              context,
              title: 'Sheet title',
              builder: (c) => TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Close'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Sheet title'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Sheet title'), findsNothing);
  });

  testWidgets('Surfaces, background, emblem, burst', (tester) async {
    final burst = CelebrationController();
    addTearDown(burst.dispose);
    await tester.pumpWidget(
      _app(
        SizedBox(
          height: 900,
          child: HudBackground(
            child: Column(
              children: [
                const GlassPanel(blur: 10, glow: true, child: Text('Glass')),
                const HudFrame(
                  ticks: true,
                  tag: 'SYS',
                  child: SizedBox(height: 40),
                ),
                const AthleteEmblem(size: 80, detail: true),
                CelebrationBurst(
                  controller: burst,
                  haptic: true,
                  child: const SizedBox(width: 60, height: 60),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    burst.fire();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('Glass'), findsOneWidget);
  });

  testWidgets('JarvisOrb runs every state and reacts to levels', (
    tester,
  ) async {
    final levels = StreamController<double>();
    addTearDown(levels.close);
    for (final s in OrbState.values) {
      await tester.pumpWidget(
        _app(JarvisOrb(state: s, level: levels.stream, size: 120)),
      );
      levels.add(0.8);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.bySemanticsLabel('Assistant speaking'), findsOneWidget);
  });

  testWidgets('ArcGauge, HudSparkline and HudChartStyle charts', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Column(
            children: [
              const ArcGauge(value: 0.7, valueText: '70', label: 'READY'),
              const HudSparkline(values: [1, 3, 2, 5, 4]),
              const HudSparkline(values: [1]),
              SizedBox(
                height: 120,
                child: LineChart(
                  LineChartData(
                    gridData: HudChartStyle.grid(context),
                    borderData: HudChartStyle.noBorder,
                    titlesData: HudChartStyle.titles(
                      context,
                      bottom: (v, m) => Text('$v'),
                      left: (v, m) => Text('$v'),
                    ),
                    lineTouchData: HudChartStyle.lineTouch(
                      context,
                      unit: ' kg',
                    ),
                    lineBarsData: [
                      HudChartStyle.line(
                        const [FlSpot(0, 1), FlSpot(1, 3), FlSpot(2, 2)],
                        AppColors.strength,
                        dots: true,
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                height: 120,
                child: BarChart(
                  BarChartData(
                    barTouchData: HudChartStyle.barTouch(context),
                    barGroups: [
                      BarChartGroupData(
                        x: 0,
                        barRods: [
                          HudChartStyle.rod(
                            3,
                            AppColors.calories,
                            backgroundMax: 5,
                          ),
                        ],
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
    await _settle(tester);
    expect(find.text('70'), findsOneWidget);
  });

  testWidgets('HudDock selects with a haptic and exposes labels', (
    tester,
  ) async {
    final events = <String>[];
    Haptics.debugOnEvent = events.add;
    var index = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            extendBody: true,
            body: const SizedBox.expand(),
            bottomNavigationBar: HudDock(
              currentIndex: index,
              onSelect: (i) => setState(() => index = i),
              items: const [
                HudDockItem(
                  icon: Icons.home_outlined,
                  selectedIcon: Icons.home,
                  label: 'Home',
                ),
                HudDockItem(
                  icon: Icons.star_border,
                  selectedIcon: Icons.star,
                  label: 'Orb',
                  orb: true,
                ),
                HudDockItem(
                  icon: Icons.person_outline,
                  selectedIcon: Icons.person,
                  label: 'Me',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Me'));
    await tester.pump(const Duration(milliseconds: 800));
    expect(index, 2);
    expect(events, ['selection']);
    await tester.tap(find.text('Orb'));
    await tester.pump(const Duration(milliseconds: 800));
    expect(index, 1);
  });

  testWidgets('components survive 1.3× text on a 360 dp phone', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 780 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        textScale: 1.3,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader('Productivity & well-being', action: 'See all'),
            const Row(
              children: [
                Expanded(
                  child: StatTile(
                    label: 'Resting heart rate',
                    value: '54 bpm',
                    sub: 'Health Connect',
                  ),
                ),
                Expanded(
                  child: StatTile(label: 'Sleep', value: '7h 42m'),
                ),
              ],
            ),
            const MetricBar(
              label: 'Protein',
              value: 112,
              target: 150,
              color: AppColors.protein,
              unit: ' g',
            ),
            const NoticeBanner(
              message: 'Showing sample data until Health Connect is linked.',
              actionLabel: 'Connect',
            ),
            HudButton(label: 'Start workout', onPressed: () {}, expand: true),
            SegmentedHud<int>(
              value: 0,
              onChanged: (_) {},
              segments: const [
                HudSegment(value: 0, label: 'Day'),
                HudSegment(value: 1, label: 'Week'),
                HudSegment(value: 2, label: 'Month'),
              ],
            ),
            const EmptyState(
              icon: Icons.inbox,
              title: 'No meals logged yet',
              message: 'Snap a photo or search a food.',
              actionLabel: 'Log a meal',
            ),
          ],
        ),
      ),
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('light theme renders the same components', (tester) async {
    await tester.pumpWidget(
      _app(
        light: true,
        const Column(
          children: [
            AppCard(accent: AppColors.red, child: Text('Light')),
            ProgressRing(progress: 0.4, color: AppColors.red),
            HudButton(label: 'CTA', onPressed: null),
          ],
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('Light'), findsOneWidget);
  });
}
