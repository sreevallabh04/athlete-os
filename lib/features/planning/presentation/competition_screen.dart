import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../application/planning_providers.dart';
import '../data/planning_repository.dart';
import 'widgets/competition_editor.dart';
import 'widgets/countdown_hero.dart';
import 'widgets/milestones_section.dart';
import 'widgets/progress_photos_section.dart';
import 'widgets/progress_review_section.dart';
import 'widgets/ui_helpers.dart';

class CompetitionScreen extends ConsumerWidget {
  const CompetitionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(competitionViewProvider);
    return AppPage(
      title: 'Competition prep',
      actions: [
        if (view.value != null)
          IconButton(
            tooltip: 'Edit competition',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => showCompetitionEditor(
              context,
              existing: view.value!.competition,
            ),
          ),
      ],
      children: [
        view.when(
          loading: () => const LoadingState(),
          error: (e, _) => ErrorState(
            message: 'Could not load your competition.',
            onRetry: () => ref.invalidate(competitionViewProvider),
          ),
          data: (v) => v == null ? const _NoCompetition() : _Prep(view: v),
        ),
      ],
    );
  }
}

class _NoCompetition extends StatelessWidget {
  const _NoCompetition();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CompetitionCta(onTap: () => showCompetitionEditor(context)),
        const SizedBox(height: AppSpacing.lg),
        const EmptyState(
          icon: Icons.emoji_events_outlined,
          title: 'No competition set',
          message:
              'Add your event date and timezone to start a countdown, a prep '
              'timeline, a checklist and weekly progress reviews.',
        ),
        const _SafetyCard(),
      ],
    );
  }
}

class _Prep extends ConsumerWidget {
  const _Prep({required this.view});
  final CompetitionView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = view.countdown;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final left = <Widget>[
          CountdownHero(view: view, large: true),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Hint(
                  view.prepStartOverride != null
                      ? 'Prep start: ${formatDateKey(view.prepStartOverride!)} (set by you)'
                      : c.prepStart != null
                      ? 'Prep start: ${formatDateKey(c.prepStart!.key)} '
                            '(when you created the competition)'
                      : 'Prep start not set',
                ),
              ),
              TextButton(
                onPressed: () async {
                  final d = await pickDateKey(
                    context,
                    initial: c.prepStart?.key,
                    helpText: 'Prep start date',
                  );
                  if (d != null) {
                    await ref
                        .read(planningRepositoryProvider)
                        .setPrepStart(view.competition.id, d);
                  }
                },
                child: const Text('Set prep start'),
              ),
            ],
          ),
          if (view.competition.notes != null) ...[
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const CardTitle(icon: Icons.notes, title: 'Notes'),
                  const SizedBox(height: AppSpacing.sm),
                  Text(view.competition.notes!),
                ],
              ),
            ),
          ],
          const SectionHeader(
            'Plan',
            subtitle: 'Milestones and prep checklist',
          ),
          MilestonesSection(view: view),
        ];
        final right = <Widget>[
          const SectionHeader(
            'Weekly progress review',
            subtitle: 'Computed from your logged and synced data',
          ),
          const ProgressReviewSection(),
          const SectionHeader('Progress photos'),
          const ProgressPhotosSection(),
          const _SafetyCard(),
        ];
        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [...left, ...right],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: left,
              ),
            ),
            const SizedBox(width: AppSpacing.xl),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: right,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SafetyCard extends StatelessWidget {
  const _SafetyCard();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl),
      child: AppCard(
        accent: AppColors.warning,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const CardTitle(
              icon: Icons.health_and_safety_outlined,
              title: 'Prep safely',
              color: AppColors.warning,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Athlete OS will never suggest extreme calorie cuts, '
              'dehydration, water loading/cutting, diuretics or other '
              'drug-based weight manipulation. These carry real health risks.',
              style: t.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Plan peak week, any significant diet changes and posing load '
              'with a qualified coach, registered dietitian or doctor — '
              'especially if you have a medical condition.',
              style: t.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
