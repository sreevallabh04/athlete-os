import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Base surface for dashboard content. Optionally tinted with an accent
/// gradient and tappable.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.accent,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.gradient,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Color? accent;
  final EdgeInsetsGeometry padding;
  final Gradient? gradient;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final decoration = BoxDecoration(
      color: gradient == null ? scheme.surface : null,
      gradient:
          gradient ?? (accent != null ? AppGradients.subtle(accent!) : null),
      borderRadius: AppRadii.card,
      border: Border.all(
        color: (accent ?? scheme.outlineVariant).withValues(
          alpha: accent != null ? 0.35 : 0.6,
        ),
      ),
    );
    final content = Padding(padding: padding, child: child);
    return Semantics(
      label: semanticLabel,
      button: onTap != null,
      container: true,
      child: DecoratedBox(
        decoration: decoration,
        child: Material(
          type: MaterialType.transparency,
          child: onTap == null
              ? content
              : InkWell(
                  borderRadius: AppRadii.card,
                  onTap: onTap,
                  child: content,
                ),
        ),
      ),
    );
  }
}

/// Section title with optional trailing action, used between cards.
class SectionHeader extends StatelessWidget {
  const SectionHeader(
    this.title, {
    super.key,
    this.action,
    this.onAction,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl, bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(title, style: t.titleMedium),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: t.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (action != null)
            TextButton(onPressed: onAction, child: Text(action!)),
        ],
      ),
    );
  }
}
