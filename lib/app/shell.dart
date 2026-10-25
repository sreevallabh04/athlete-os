import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/haptics/haptics.dart';
import '../core/motion/motion_tokens.dart';
import '../core/theme/hud_theme.dart';
import '../core/widgets/dock.dart';
import '../core/widgets/orb.dart';

/// Navigation shell: Today · Train · Nutrition · AI Coach · Life.
///
/// Phones get the floating glass [HudDock] (content insets come from
/// `Scaffold.extendBody`, i.e. `MediaQuery.padding.bottom`); wide screens
/// (≥ 840 dp) get a glass navigation rail.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  static const items = [
    HudDockItem(
      icon: Icons.wb_sunny_outlined,
      selectedIcon: Icons.wb_sunny,
      label: 'Today',
    ),
    HudDockItem(
      icon: Icons.fitness_center_outlined,
      selectedIcon: Icons.fitness_center,
      label: 'Train',
    ),
    HudDockItem(
      icon: Icons.restaurant_outlined,
      selectedIcon: Icons.restaurant,
      label: 'Nutrition',
    ),
    HudDockItem(
      icon: Icons.auto_awesome_outlined,
      selectedIcon: Icons.auto_awesome,
      label: 'AI Coach',
      orb: true,
    ),
    HudDockItem(
      icon: Icons.self_improvement_outlined,
      selectedIcon: Icons.self_improvement,
      label: 'Life',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    void go(int i) =>
        shell.goBranch(i, initialLocation: i == shell.currentIndex);
    final body = _TabFade(index: shell.currentIndex, child: shell);
    if (wide) {
      final hud = HudTheme.of(context);
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Row(
          children: [
            ClipRect(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: hud.glassFillStrong,
                    border: Border(
                      right: BorderSide(
                        color: hud.hairline.withValues(alpha: 0.14),
                      ),
                    ),
                  ),
                  child: NavigationRail(
                    selectedIndex: shell.currentIndex,
                    onDestinationSelected: (i) {
                      Haptics.selection();
                      go(i);
                    },
                    labelType: NavigationRailLabelType.all,
                    groupAlignment: -0.6,
                    destinations: [
                      for (final d in items)
                        NavigationRailDestination(
                          icon: d.orb
                              ? const JarvisOrb(size: 30, fps: 30)
                              : Icon(d.icon),
                          selectedIcon: d.orb
                              ? const JarvisOrb(
                                  size: 34,
                                  fps: 30,
                                  state: OrbState.speaking,
                                )
                              : Icon(d.selectedIcon),
                          label: Text(d.label),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      );
    }
    final hud = HudTheme.of(context);
    final scrimH =
        MediaQuery.viewPaddingOf(context).bottom +
        HudDock.barHeight +
        HudDock.bottomGap +
        40;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          body,
          // Content dissolves into the canvas as it slides under the dock.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: scrimH,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      hud.canvasBottom.withValues(alpha: 0),
                      hud.canvasBottom.withValues(alpha: 0.82),
                      hud.canvasBottom.withValues(alpha: 0.95),
                    ],
                    stops: const [0, 0.55, 1],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: HudDock(
        items: items,
        currentIndex: shell.currentIndex,
        onSelect: go,
      ),
    );
  }
}

/// Fade-through when switching tabs: the new branch rises in from 98 %
/// while fading up (the old one is already hidden by the indexed stack).
class _TabFade extends StatefulWidget {
  const _TabFade({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  State<_TabFade> createState() => _TabFadeState();
}

class _TabFadeState extends State<_TabFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: AppMotion.medium,
    value: 1,
  );

  @override
  void didUpdateWidget(_TabFade old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index && !AppMotion.reduced(context)) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    child: widget.child,
    builder: (context, child) {
      // Constant tree shape: never reparent the navigation shell.
      final v = AppMotion.emphasizedDecelerate.transform(_c.value);
      return Opacity(
        opacity: v,
        child: Transform.scale(scale: 0.98 + 0.02 * v, child: child),
      );
    },
  );
}
