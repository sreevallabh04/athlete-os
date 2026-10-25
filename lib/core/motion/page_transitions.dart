import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'motion_tokens.dart';

/// "Zoom-through": the incoming page scales up from 94 % while fading in
/// after a short beat; the outgoing page drifts forward (104 %) and fades.
/// Overlap is minimal, so translucent HUD pages never ghost over each other.
///
/// Installed for Android/Fuchsia/Windows/Linux via the theme's
/// [PageTransitionsTheme]; iOS/macOS keep the native swipe-back transition.
class HudPageTransitionsBuilder extends PageTransitionsBuilder {
  const HudPageTransitionsBuilder();

  @override
  Duration get transitionDuration => AppMotion.page;

  @override
  Duration get reverseTransitionDuration => AppMotion.pageReverse;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => HudZoomThrough(
    animation: animation,
    secondaryAnimation: secondaryAnimation,
    child: child,
  );
}

/// The transition used by [HudPageTransitionsBuilder] and [hudPage].
class HudZoomThrough extends StatelessWidget {
  const HudZoomThrough({
    super.key,
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  static final _inFade = CurveTween(
    curve: const Interval(0.18, 1, curve: AppMotion.emphasizedDecelerate),
  );
  static final _inScale = Tween(
    begin: 0.94,
    end: 1.0,
  ).chain(CurveTween(curve: AppMotion.emphasizedDecelerate));
  static final _outFade = Tween(
    begin: 1.0,
    end: 0.0,
  ).chain(CurveTween(curve: const Interval(0, 0.45, curve: Curves.easeOut)));
  static final _outScale = Tween(
    begin: 1.0,
    end: 1.04,
  ).chain(CurveTween(curve: AppMotion.emphasizedAccelerate));

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    return FadeTransition(
      opacity: _outFade.animate(secondaryAnimation),
      child: ScaleTransition(
        scale: _outScale.animate(secondaryAnimation),
        child: FadeTransition(
          opacity: _inFade.animate(animation),
          child: ScaleTransition(
            scale: _inScale.animate(animation),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// GoRouter page using the HUD transition. Use in `pageBuilder:`
///
/// ```dart
/// GoRoute(
///   path: AppPaths.reports,
///   pageBuilder: (c, s) => hudPage(s, const ReportsScreen()),
/// )
/// ```
CustomTransitionPage<T> hudPage<T>(
  GoRouterState state,
  Widget child, {
  bool fullscreenDialog = false,
}) => CustomTransitionPage<T>(
  key: state.pageKey,
  name: state.name,
  arguments: state.extra,
  fullscreenDialog: fullscreenDialog,
  transitionDuration: AppMotion.page,
  reverseTransitionDuration: AppMotion.pageReverse,
  transitionsBuilder: (context, animation, secondary, child) => HudZoomThrough(
    animation: animation,
    secondaryAnimation: secondary,
    child: child,
  ),
  child: child,
);
