import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/config/env.dart';
import '../../../core/domain/provenance.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../application/train_providers.dart';
import '../domain/running_models.dart';
import '../domain/strength_analytics.dart';
import '../domain/strength_models.dart';
import '../../onboarding/presentation/program_screen.dart';
import 'log_workout_screen.dart';
import 'widgets/strava_branding.dart';
import 'widgets/sync_status.dart';

class TrainScreen extends ConsumerWidget {
  const TrainScreen({super.key});

  Future<void> _sync(
    BuildContext context,
    Future<String> Function() run,
  ) async {
    final msg = await run();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workoutsAsync = ref.watch(workoutLogsProvider);
    final cardioAsync = ref.watch(cardioActivitiesProvider);
    final hevy = ref.watch(integrationStatusProvider(Providers.hevy)).value;
    final strava = ref.watch(integrationStatusProvider(Providers.strava)).value;
    final sync = ref.watch(syncControllerProvider);
    final now = ref.watch(clockProvider).now();
    final today = ref.watch(todayKeyProvider);
    final weekStart = LocalDates.weekStart(today);
    final controller = ref.read(syncControllerProvider.notifier);

    Future<void> refresh() async {
      if (isConnected(hevy)) await controller.syncHevy();
      if (Env.hasStrava && isConnected(strava)) await controller.syncStrava();
    }

    final children = <Widget>[const PlannedSessionCard()];
    if (workoutsAsync.isLoading || cardioAsync.isLoading) {
      children.add(const LoadingState());
    } else if (workoutsAsync.hasError || cardioAsync.hasError) {
      children.add(
        const ErrorState(
          message: 'Could not load training data from this device.',
        ),
      );
    } else {
      final workouts = workoutsAsync.value ?? const <WorkoutLog>[];
      final cardio = cardioAsync.value ?? const <RunActivity>[];
      final weekWorkouts = workouts
          .where((w) => LocalDates.weekStart(w.localDate) == weekStart)
          .toList();
      final weekRuns = cardio
          .where(
            (a) => a.isRun && LocalDates.weekStart(a.localDate) == weekStart,
          )
          .toList();
      final hasStrava = cardio.any((a) => a.isStrava);

      if (workouts.isEmpty && cardio.isEmpty) {
        children.add(
          AppCard(
            child: EmptyState(
              icon: Icons.fitness_center,
              title: 'No training data yet',
              message:
                  'Connect Hevy (needs Hevy Pro) to import your lifting, '
                  'connect Strava for runs, or log a workout manually. '
                  'Runs from Health Connect also appear here.',
              actionLabel: 'Connect apps',
              onAction: () => context.push(AppPaths.integrations),
            ),
          ),
        );
        children.add(const SizedBox(height: AppSpacing.md));
        children.add(
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => LogWorkoutScreen.open(context),
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Log manually'),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => showCsvImportDialog(context, ref),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Import CSV'),
                ),
              ),
            ],
          ),
        );
      } else {
        children.add(
          _WeekCard(
            workouts: weekWorkouts,
            runs: weekRuns,
            weekStart: weekStart,
          ),
        );
        if (workouts.isNotEmpty) {
          children.add(const SectionHeader('Latest workout'));
          children.add(_LatestWorkoutCard(workout: workouts.first, now: now));
        }
        final latestRun = cardio.where((a) => a.isRun).firstOrNull;
        if (latestRun != null) {
          children.add(const SectionHeader('Latest run'));
          children.add(_LatestRunCard(run: latestRun, now: now));
        }
        if (hasStrava) children.add(const PoweredByStrava());
      }
    }

    children.addAll([
      const SectionHeader('Explore'),
      Row(
        children: [
          Expanded(
            child: _QuickLink(
              icon: Icons.fitness_center,
              label: 'Strength',
              color: AppColors.strength,
              onTap: () => context.push(AppPaths.strength),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: _QuickLink(
              icon: Icons.directions_run,
              label: 'Running',
              color: AppColors.running,
              onTap: () => context.push(AppPaths.running),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: _QuickLink(
              icon: Icons.directions_walk,
              label: 'Steps',
              color: AppColors.steps,
              onTap: () => context.push(AppPaths.steps),
            ),
          ),
        ],
      ),
      const SectionHeader('Sync', subtitle: 'Read-only imports from your apps'),
      AppCard(
        child: Column(
          children: [
            SyncStatusTile(
              name: 'Hevy',
              color: AppColors.strength,
              row: hevy,
              configured: true,
              syncing: sync.hevy,
              onSync: () => _sync(context, controller.syncHevy),
              onSetup: () => context.push(AppPaths.integrations),
              now: now,
            ),
            const Divider(height: AppSpacing.xl),
            SyncStatusTile(
              name: 'Strava',
              color: AppColors.running,
              row: strava,
              configured: Env.hasStrava,
              syncing: sync.strava,
              onSync: () => _sync(context, controller.syncStrava),
              onSetup: () => context.push(AppPaths.integrations),
              now: now,
            ),
          ],
        ),
      ),
    ]);

    return AppPage(
      title: 'Train',
      onRefresh: refresh,
      actions: [
        PopupMenuButton<String>(
          tooltip: 'Add training',
          icon: const Icon(Icons.add_circle_outline),
          onSelected: (v) {
            if (v == 'log') LogWorkoutScreen.open(context);
            if (v == 'csv') showCsvImportDialog(context, ref);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'log', child: Text('Log workout manually')),
            PopupMenuItem(value: 'csv', child: Text('Import Hevy CSV')),
          ],
        ),
      ],
      children: children,
    );
  }
}

class _WeekCard extends StatelessWidget {
  const _WeekCard({
    required this.workouts,
    required this.runs,
    required this.weekStart,
  });
  final List<WorkoutLog> workouts;
  final List<RunActivity> runs;
  final String weekStart;

  @override
  Widget build(BuildContext context) {
    final sets = workouts.fold(0, (a, w) => a + workingSetCount(w));
    final volume = workouts.fold(0.0, (a, w) => a + sessionVolume(w));
    final km = runs.fold(0.0, (a, r) => a + (r.distanceM ?? 0)) / 1000;
    return AppCard(
      accent: AppColors.strength,
      semanticLabel: 'This week training summary',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This week · from ${Fmt.dayMonth(LocalDates.parse(weekStart))}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Lifting',
                  value: '${workouts.length}',
                  sub: workouts.length == 1 ? 'session' : 'sessions',
                  icon: Icons.fitness_center,
                  color: AppColors.strength,
                ),
              ),
              Expanded(
                child: StatTile(
                  label: 'Working sets',
                  value: '$sets',
                  sub: '${Fmt.integer(volume)} kg vol.',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Runs',
                  value: '${runs.length}',
                  icon: Icons.directions_run,
                  color: AppColors.running,
                ),
              ),
              Expanded(
                child: StatTile(
                  label: 'Distance',
                  value: '${km.toStringAsFixed(1)} km',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LatestWorkoutCard extends StatelessWidget {
  const _LatestWorkoutCard({required this.workout, required this.now});
  final WorkoutLog workout;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final d = workout.duration;
    return AppCard(
      onTap: () => context.push('/workout/${workout.id}'),
      semanticLabel: 'Latest workout ${workout.title}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(workout.title, style: t.titleMedium)),
              SourceBadge(origin: DataOrigin.fromKey(workout.source)),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            [
              Fmt.weekdayDayMonth(workout.startAt),
              if (d != null && d.inMinutes > 0) '${d.inMinutes} min',
              '${workout.exercises.length} exercises',
              '${workingSetCount(workout)} sets',
              '${Fmt.integer(sessionVolume(workout))} kg',
            ].join(' · '),
            style: t.bodySmall,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            workout.exercises.take(4).map((e) => e.name).join(', ') +
                (workout.exercises.length > 4 ? '…' : ''),
            style: t.bodyMedium,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _LatestRunCard extends StatelessWidget {
  const _LatestRunCard({required this.run, required this.now});
  final RunActivity run;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AppCard(
      onTap: () => context.push('/running/activity/${run.id}'),
      semanticLabel: 'Latest run',
      child: Row(
        children: [
          const Icon(Icons.directions_run, color: AppColors.running),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(run.name ?? 'Run', style: t.titleSmall),
                Text(
                  [
                    Fmt.weekdayDayMonth(run.startAt),
                    if (run.distanceM != null) Fmt.km(run.distanceM!),
                    if (run.paceSPerKm != null) Fmt.pace(run.paceSPerKm!),
                  ].join(' · '),
                  style: t.bodySmall,
                ),
              ],
            ),
          ),
          SourceBadge(origin: DataOrigin.fromKey(run.source)),
        ],
      ),
    );
  }
}

class _QuickLink extends StatelessWidget {
  const _QuickLink({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => AppCard(
    accent: color,
    onTap: onTap,
    semanticLabel: label,
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
    child: Column(
      children: [
        Icon(icon, color: color),
        const SizedBox(height: AppSpacing.xs),
        Text(label, style: Theme.of(context).textTheme.labelLarge),
      ],
    ),
  );
}
