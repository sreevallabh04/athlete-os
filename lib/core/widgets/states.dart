import 'package:flutter/material.dart';

import '../domain/provenance.dart';
import '../theme/tokens.dart';
import '../util/format.dart';

/// Empty state with an icon, message and optional call to action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.all(compact ? AppSpacing.md : AppSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 28 : 44, color: scheme.onSurfaceVariant),
          const SizedBox(height: AppSpacing.md),
          Text(title, style: t.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              message!,
              style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
          if (actionLabel != null) ...[
            const SizedBox(height: AppSpacing.lg),
            FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: Icons.error_outline,
    title: 'Something went wrong',
    message: message,
    actionLabel: onRetry == null ? null : 'Retry',
    onAction: onRetry,
  );
}

class LoadingState extends StatelessWidget {
  const LoadingState({super.key});
  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(AppSpacing.xxl),
      child: CircularProgressIndicator(),
    ),
  );
}

/// Small pill showing where a value came from and how fresh it is,
/// e.g. "Health Connect · 12 min ago" or "AI estimate".
class SourceBadge extends StatelessWidget {
  const SourceBadge({
    super.key,
    required this.origin,
    this.asOf,
    this.isEstimate = false,
    this.now,
    this.staleAfter = const Duration(hours: 3),
  });

  final DataOrigin origin;
  final DateTime? asOf;
  final bool isEstimate;
  final DateTime? now;
  final Duration staleAfter;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = now ?? DateTime.now();
    final stale = asOf != null && n.difference(asOf!) > staleAfter;
    final color = origin == DataOrigin.sample
        ? AppColors.warning
        : isEstimate
        ? AppColors.warning
        : stale
        ? AppColors.warning
        : scheme.onSurfaceVariant;
    final parts = <String>[
      origin.label,
      if (isEstimate && origin != DataOrigin.aiEstimate) 'estimate',
      if (asOf != null) Fmt.ago(asOf!, n),
      if (stale) 'stale',
    ];
    return Semantics(
      label: 'Source: ${parts.join(', ')}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 3,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: AppRadii.chip,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isEstimate || origin == DataOrigin.sample
                  ? Icons.auto_awesome_outlined
                  : stale
                  ? Icons.schedule
                  : Icons.verified_outlined,
              size: 12,
              color: color,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                parts.join(' · '),
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact stat: big number + label + optional sub-line.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.sub,
    this.icon,
    this.color,
  });

  final String label;
  final String value;
  final String? sub;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '$label: $value${sub != null ? ', $sub' : ''}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: color ?? scheme.onSurfaceVariant),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  style: t.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(value, style: t.titleLarge),
          if (sub != null)
            Text(
              sub!,
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

/// Clearly-labelled banner for data that is unavailable, stale or sample.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({
    super.key,
    required this.message,
    this.icon = Icons.info_outline,
    this.color = AppColors.info,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final IconData icon;
  final Color color;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodyMedium),
          ),
          if (actionLabel != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}
