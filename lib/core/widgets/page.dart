import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../motion/entrance.dart';
import '../motion/motion_tokens.dart';
import '../theme/hud_theme.dart';
import '../theme/tokens.dart';

/// Standard scrollable page with a large collapsing HUD title. Use for every
/// top-level and secondary screen so spacing stays consistent.
///
/// * Transparent: the app-wide `HudBackground` shows through.
/// * Large title blurs in on first appearance, then collapses into a glass
///   bar (backdrop blur only once content scrolls underneath).
/// * Cards inside cascade in automatically (`EntranceScope`).
/// * Bottom padding includes the floating dock inset (MediaQuery padding).
class AppPage extends StatefulWidget {
  const AppPage({
    super.key,
    required this.title,
    required this.children,
    this.actions,
    this.subtitle,
    this.onRefresh,
    this.floatingActionButton,
    this.bottomAction,
    this.showBack,
    this.eyebrow,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final List<Widget>? actions;
  final Future<void> Function()? onRefresh;
  final Widget? floatingActionButton;

  /// The screen's primary action, docked in a frosted bar at the bottom.
  /// Use it on pushed screens (Journal "Write", Mood "Check in"…): unlike a
  /// floating button it never covers content, because the list ends above
  /// it. Pass an expanded `HudButton`.
  final Widget? bottomAction;

  /// Defaults to automatic (shows when the route can pop).
  final bool? showBack;

  /// Optional small mono telemetry line above the large title, e.g.
  /// `'SAT 25 OCT · 21:40'`. Pass UPPERCASE.
  final String? eyebrow;

  @override
  State<AppPage> createState() => _AppPageState();
}

class _AppPageState extends State<AppPage> {
  final _entrances = EntranceCoordinator();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = HudTheme.of(context);
    final mq = MediaQuery.of(context);
    final route = ModalRoute.of(context);
    final canPop = route?.impliesAppBarDismissal ?? false;
    final fullscreen = route is PageRoute && route.fullscreenDialog;
    final leading = (widget.showBack ?? true) && canPop
        ? (fullscreen ? const CloseButton() : const BackButton())
        : null;

    Widget scroll = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _HudHeaderDelegate(
            title: widget.title,
            eyebrow: widget.eyebrow,
            leading: leading,
            actions: widget.actions,
            topPadding: mq.padding.top,
            titleExtent: mq.textScaler.scale(34),
            hud: hud,
            titleStyle: t.headlineMedium!,
            barTitleStyle: t.titleMedium!,
            reduced: AppMotion.reduced(context),
          ),
        ),
        if (widget.subtitle != null)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
            sliver: SliverToBoxAdapter(
              child: Text(
                widget.subtitle!,
                style: t.bodyMedium?.copyWith(color: hud.textMuted),
              ),
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.md,
            AppSpacing.gutter,
            // The bottom action bar already clears the system inset.
            widget.bottomAction != null
                ? AppSpacing.xl
                : mq.padding.bottom + AppSpacing.xxxl,
          ),
          sliver: SliverList.list(children: widget.children),
        ),
      ],
    );
    if (widget.onRefresh != null) {
      scroll = RefreshIndicator(
        onRefresh: widget.onRefresh!,
        edgeOffset: mq.padding.top + 56,
        child: scroll,
      );
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: EntranceScope(coordinator: _entrances, child: scroll),
      floatingActionButton: widget.floatingActionButton,
      bottomNavigationBar: widget.bottomAction == null
          ? null
          : _BottomActionBar(child: widget.bottomAction!),
    );
  }
}

class _HudHeaderDelegate extends SliverPersistentHeaderDelegate {
  _HudHeaderDelegate({
    required this.title,
    required this.eyebrow,
    required this.leading,
    required this.actions,
    required this.topPadding,
    required this.titleExtent,
    required this.hud,
    required this.titleStyle,
    required this.barTitleStyle,
    required this.reduced,
  });

  final String title;
  final String? eyebrow;
  final Widget? leading;
  final List<Widget>? actions;
  final double topPadding;
  final double titleExtent;
  final HudTheme hud;
  final TextStyle titleStyle;
  final TextStyle barTitleStyle;
  final bool reduced;

  static const _bar = 56.0;

  double get _expandedExtra => titleExtent + (eyebrow != null ? 36 : 22);

  @override
  double get minExtent => topPadding + _bar;

  @override
  double get maxExtent => topPadding + _bar + _expandedExtra;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    final range = maxExtent - minExtent;
    final t = range <= 0 ? 1.0 : (shrinkOffset / range).clamp(0.0, 1.0);
    final barT = Curves.easeIn.transform(((t - 0.55) / 0.45).clamp(0.0, 1.0));
    final glassT = overlaps || t >= 1 ? 1.0 : barT;

    Widget background = Container(
      decoration: BoxDecoration(
        color: hud.glassFillStrong.withValues(
          alpha: hud.glassFillStrong.a * glassT,
        ),
        border: Border(
          bottom: BorderSide(
            color: hud.hairline.withValues(alpha: 0.14 * glassT),
          ),
        ),
      ),
    );
    if (glassT > 0.01) {
      background = ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18 * glassT, sigmaY: 18 * glassT),
          child: background,
        ),
      );
    }

    final largeOpacity = (1 - t * 1.6).clamp(0.0, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        background,
        // Large title block.
        Positioned(
          left: AppSpacing.gutter,
          right: AppSpacing.gutter,
          bottom: 10,
          child: IgnorePointer(
            ignoring: largeOpacity < 0.5,
            child: Opacity(
              opacity: largeOpacity,
              child: Transform.translate(
                offset: Offset(0, -12 * t),
                child: Entrance(
                  enabled: !reduced,
                  blur: 8,
                  offset: const Offset(0, 10),
                  duration: AppMotion.entrance,
                  child: _LargeTitle(
                    title: title,
                    eyebrow: eyebrow,
                    style: titleStyle,
                    hud: hud,
                  ),
                ),
              ),
            ),
          ),
        ),
        // Bar row.
        Positioned(
          top: topPadding,
          left: 0,
          right: 0,
          height: _bar,
          child: NavigationToolbar(
            leading: leading,
            middle: Opacity(
              opacity: barT,
              child: Text(
                title,
                style: barTitleStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            trailing: actions == null
                ? null
                : Row(mainAxisSize: MainAxisSize.min, children: actions!),
            centerMiddle: true,
            middleSpacing: AppSpacing.lg,
          ),
        ),
      ],
    );
  }

  @override
  bool shouldRebuild(_HudHeaderDelegate old) =>
      old.title != title ||
      old.eyebrow != eyebrow ||
      old.leading.runtimeType != leading.runtimeType ||
      old.actions != actions ||
      old.topPadding != topPadding ||
      old.titleExtent != titleExtent ||
      old.hud != hud ||
      old.titleStyle != titleStyle ||
      old.reduced != reduced;
}

class _LargeTitle extends StatelessWidget {
  const _LargeTitle({
    required this.title,
    required this.eyebrow,
    required this.style,
    required this.hud,
  });

  final String title;
  final String? eyebrow;
  final TextStyle style;
  final HudTheme hud;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (eyebrow != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            eyebrow!,
            style: hud.mono(size: 10.5, color: hud.accentInk),
            maxLines: 1,
          ),
        ),
      Semantics(
        header: true,
        child: Text(
          title,
          style: style.copyWith(fontSize: 30),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      const SizedBox(height: 8),
      ExcludeSemantics(
        child: SizedBox(
          height: 3,
          width: double.infinity,
          child: CustomPaint(painter: _TitleRulePainter(hud.accent)),
        ),
      ),
    ],
  );
}

/// The HUD rule under a large title: a short glowing segment, a gap, then a
/// hairline fading to nothing with a few ticks.
class _TitleRulePainter extends CustomPainter {
  const _TitleRulePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    canvas.drawLine(
      Offset(0, y),
      Offset(28, y),
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 2),
    );
    canvas.drawLine(
      Offset(34, y),
      Offset(size.width, y),
      Paint()
        ..strokeWidth = 1
        ..shader = LinearGradient(
          colors: [color.withValues(alpha: 0.35), color.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(34, 0, math.max(1, size.width - 34), 1)),
    );
    final tick = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (var i = 0; i < 3; i++) {
      final x = 40.0 + i * 5;
      canvas.drawLine(Offset(x, y - 1.5), Offset(x, y + 1.5), tick);
    }
  }

  @override
  bool shouldRepaint(_TitleRulePainter old) => old.color != color;
}

/// Adds vertical spacing between a list of widgets.
List<Widget> spaced(List<Widget> children, {double gap = AppSpacing.md}) {
  final out = <Widget>[];
  for (var i = 0; i < children.length; i++) {
    if (i > 0) out.add(SizedBox(height: gap));
    out.add(children[i]);
  }
  return out;
}

class _BottomActionBar extends StatelessWidget {
  const _BottomActionBar({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: hud.glassFillStrong,
            border: Border(
              top: BorderSide(color: hud.hairline.withValues(alpha: 0.14)),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.md,
              AppSpacing.gutter,
              AppSpacing.md + bottom,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
