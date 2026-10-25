import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../haptics/haptics.dart';
import '../motion/motion_tokens.dart';
import '../theme/hud_theme.dart';
import '../theme/tokens.dart';

/// Shows a frosted HUD sheet that rises on a gentle spring.
///
/// ```dart
/// final picked = await showHudBottomSheet<String>(
///   context,
///   title: 'Log water',
///   builder: (context) => const WaterPicker(),
/// );
/// ```
Future<T?> showHudBottomSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  String? title,
  bool isScrollControlled = true,
  bool useRootNavigator = true,
  bool isDismissible = true,
}) {
  Haptics.light();
  final reduced = AppMotion.reduced(context);
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    backgroundColor: Colors.transparent,
    elevation: 0,
    showDragHandle: false,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    sheetAnimationStyle: AnimationStyle(
      duration: reduced ? Duration.zero : const Duration(milliseconds: 520),
      reverseDuration: reduced ? Duration.zero : AppMotion.pageReverse,
      curve: SpringCurve(AppMotion.gentle),
      reverseCurve: AppMotion.emphasizedAccelerate,
    ),
    builder: (context) => HudSheet(title: title, child: builder(context)),
  );
}

/// The frosted sheet chrome used by [showHudBottomSheet]; usable directly
/// for custom modal routes.
class HudSheet extends StatelessWidget {
  const HudSheet({super.key, required this.child, this.title});

  final Widget child;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    final mq = MediaQuery.of(context);
    const radius = BorderRadius.vertical(top: Radius.circular(AppRadii.xl));
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  hud.glassFillStrong,
                  Color.alphaBlend(
                    hud.glassFillStrong,
                    hud.isDark ? const Color(0xFF04060B) : Colors.white,
                  ),
                ],
              ),
              border: Border(
                top: BorderSide(color: hud.accent.withValues(alpha: 0.35)),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.sm,
                  AppSpacing.gutter,
                  AppSpacing.lg,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: _HudHandle()),
                    if (title != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Semantics(
                        header: true,
                        child: Text(title!, style: t.titleLarge),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    Flexible(child: child),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HudHandle extends StatelessWidget {
  const _HudHandle();

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    return SizedBox(
      width: 64,
      height: 12,
      child: Row(
        children: [
          for (var i = 0; i < 5; i++)
            Expanded(
              child: Container(
                height: 3,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: (i == 2 ? hud.accent : hud.textMuted).withValues(
                    alpha: i == 2 ? 0.9 : 0.35,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
