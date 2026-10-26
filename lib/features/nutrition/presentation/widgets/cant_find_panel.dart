import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import 'nutrition_hud.dart';

/// "Can't find it?": the ways to add a food no database knows. Prominent
/// (with explanations) after a search with no results or an Open Food Facts
/// failure; a compact list otherwise.
class CantFindPanel extends StatelessWidget {
  const CantFindPanel({
    super.key,
    required this.query,
    required this.prominent,
    required this.onScanLabel,
    required this.onEnterLabel,
    required this.onAskJarvis,
  });

  final String query;
  final bool prominent;
  final VoidCallback onScanLabel;
  final VoidCallback onEnterLabel;
  final VoidCallback onAskJarvis;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final actions = [
      _CantFindAction(
        key: const Key('cantfind-label'),
        icon: Icons.document_scanner_outlined,
        title: 'Scan nutrition label',
        subtitle:
            'Photo of the table on the pack. JARVIS copies the values, you '
            'check them.',
        primary: true,
        dense: !prominent,
        onTap: onScanLabel,
      ),
      _CantFindAction(
        key: const Key('cantfind-manual'),
        icon: Icons.edit_note_rounded,
        title: 'Enter label values',
        subtitle: 'Type calories and macros from the pack.',
        dense: !prominent,
        onTap: onEnterLabel,
      ),
      _CantFindAction(
        key: const Key('cantfind-ai'),
        icon: Icons.auto_awesome_outlined,
        title: 'Ask JARVIS to estimate',
        subtitle: 'No pack at hand? Get an estimate, marked ESTIMATE.',
        dense: !prominent,
        ai: true,
        onTap: onAskJarvis,
      ),
    ];
    if (!prominent) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HudCaption("Can't find it?"),
          const SizedBox(height: AppSpacing.sm),
          for (final a in actions) ...[a, const SizedBox(height: 6)],
        ],
      );
    }
    return AppCard(
      accent: hud.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const GlowIcon(Icons.manage_search_rounded, size: 22),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  'Can\'t find "$query"?',
                  style: t.titleMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            "Many Indian packaged foods aren't in the food databases yet. "
            'Add it once from the label and it shows up here instantly next '
            'time.',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
          const SizedBox(height: AppSpacing.md),
          for (final a in actions) ...[
            a,
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

class _CantFindAction extends StatelessWidget {
  const _CantFindAction({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
    this.dense = false,
    this.ai = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;
  final bool dense;
  final bool ai;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return Semantics(
      button: true,
      label: ai ? '$title, AI estimate' : title,
      excludeSemantics: true,
      onTap: onTap,
      child: PressableScale(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: dense ? AppSpacing.sm : AppSpacing.md,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            color: primary ? hud.accent.withValues(alpha: 0.08) : hud.glassFill,
            border: Border.all(
              color: primary
                  ? hud.accent.withValues(alpha: 0.45)
                  : hud.hairline.withValues(alpha: 0.16),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: primary ? hud.accent : hud.text),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: t.titleSmall?.copyWith(
                              color: primary ? hud.accentInk : hud.text,
                            ),
                          ),
                        ),
                        if (ai) ...[
                          const SizedBox(width: 6),
                          Text(
                            'AI',
                            style: AppTypography.hudLabel(
                              AppColors.warning,
                              size: 9,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (!dense) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: t.bodySmall?.copyWith(color: hud.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: primary ? hud.accent : hud.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
