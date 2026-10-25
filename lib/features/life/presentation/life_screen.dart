import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/habit_providers.dart';
import '../application/mood_journal_providers.dart';
import '../application/notifications/notification_providers.dart';
import '../data/mood_repository.dart';
import '../data/notification_prefs_repository.dart';
import '../domain/habit_models.dart';
import '../domain/journal_text.dart';
import '../domain/mood_stats.dart';
import 'habits_screen.dart';
import 'journal_screen.dart';
import 'mood_check_in_sheet.dart';
import 'suggested_habits_sheet.dart';
import 'widgets/habit_widgets.dart';
import 'widgets/life_widgets.dart';
import 'widgets/mood_orb.dart';

/// Life tab hub ("Mind & habits"): today's habits as tactile chips, a mood
/// reactor with one-tap check-in, the journal with tonight's prompt, and
/// HUD tiles for planning, prep, reports, reminders and settings.
class LifeScreen extends ConsumerWidget {
  const LifeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).now();
    return AppPage(
      title: 'Life',
      eyebrow:
          '${DateFormat('EEE d MMM').format(now).toUpperCase()} · MIND & HABITS',
      showBack: false,
      children: const [
        SizedBox(height: AppSpacing.xs),
        _HabitsCard(),
        SizedBox(height: AppSpacing.md),
        _MoodCard(),
        SizedBox(height: AppSpacing.md),
        _JournalCard(),
        SectionHeader('Plan & prepare'),
        _SystemsGrid(),
      ],
    );
  }
}

// ── Habits ──────────────────────────────────────────────────────────────────

class _HabitsCard extends ConsumerStatefulWidget {
  const _HabitsCard();

  @override
  ConsumerState<_HabitsCard> createState() => _HabitsCardState();
}

class _HabitsCardState extends ConsumerState<_HabitsCard> {
  final _burst = CelebrationController();
  int? _lastRemaining;

  @override
  void dispose() {
    _burst.dispose();
    super.dispose();
  }

  void _watchAllDone(HabitBoard b) {
    final remaining = b.remainingToday;
    final prev = _lastRemaining;
    _lastRemaining = remaining;
    if (prev != null &&
        prev > 0 &&
        remaining == 0 &&
        b.doneToday > 0 &&
        LifeCelebrations.claim('habits-all', b.today)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Haptics.goalReached();
        if (!AppMotion.reduced(context)) _burst.fire();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(habitBoardProvider);
    return AppCard(
      accent: AppColors.habit,
      brackets: true,
      onTap: () => context.push(AppPaths.habits),
      semanticLabel: 'Habits',
      child: board.when(
        loading: () => const ScanlineLoader(lines: 3),
        error: (e, _) => const Text('Habits couldn\'t be loaded.'),
        data: (b) {
          _watchAllDone(b);
          return b.habits.isEmpty
              ? const _HabitsEmpty()
              : _HabitsToday(board: b, burst: _burst);
        },
      ),
    );
  }
}

class _HabitsToday extends StatelessWidget {
  const _HabitsToday({required this.board, required this.burst});
  final HabitBoard board;
  final CelebrationController burst;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final b = board;
    final due = b.dueToday.length;
    final done = b.doneToday;
    final rate = b.weekTotal.rate;
    final status = due == 0
        ? 'Nothing scheduled today'
        : b.remainingToday == 0
        ? 'All done or skipped today'
        : '$done done · ${b.remainingToday} remaining';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CelebrationBurst(
              controller: burst,
              color: AppColors.habit,
              child: ProgressRing(
                progress: due == 0 ? 0 : done / due,
                color: AppColors.habit,
                size: 74,
                stroke: 7,
                celebrate: false,
                semanticLabel: 'Habits done today',
                center: AnimatedTicker(
                  '$done/$due',
                  style: hud.number(size: 22),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('HABITS', style: hud.label(size: 11)),
                  const SizedBox(height: 2),
                  Text(status, style: t.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    rate == null
                        ? 'WEEK · NOTHING DUE YET'
                        : 'WEEK ${(rate * 100).round()}%'
                              '${b.weekTotal.skipped > 0 ? ' · ${b.weekTotal.skipped} SKIPPED' : ''}',
                    style: hud.mono(size: 11),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: hud.textMuted),
          ],
        ),
        if (b.dueToday.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          StaggeredList(
            gap: AppSpacing.sm,
            children: [
              for (final h in b.dueToday)
                HabitChip(
                  key: ValueKey(h.id),
                  view: h,
                  today: b.today,
                  expand: true,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Icon(Icons.touch_app_outlined, size: 13, color: hud.textMuted),
              const SizedBox(width: 6),
              Text('TAP = DONE · HOLD = SKIP', style: hud.label(size: 10.5)),
            ],
          ),
        ],
      ],
    );
  }
}

class _HabitsEmpty extends StatelessWidget {
  const _HabitsEmpty();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const GlowIcon(
              Icons.checklist_rtl,
              color: AppColors.habit,
              framed: true,
              size: 22,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('No habits yet', style: t.titleMedium),
                  Text(
                    'Add one or two that fit your day.',
                    style: t.bodyMedium?.copyWith(color: hud.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        const HabitQuickStart(),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            HudButton.ghost(
              label: 'More ideas',
              icon: Icons.lightbulb_outline,
              compact: true,
              onPressed: () => showSuggestedHabitsSheet(context),
            ),
            const SizedBox(width: AppSpacing.sm),
            HudButton.ghost(
              label: 'Create your own',
              icon: Icons.edit_outlined,
              compact: true,
              onPressed: () => openHabitEditor(context),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Mood ────────────────────────────────────────────────────────────────────

class _MoodCard extends ConsumerWidget {
  const _MoodCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mood = ref.watch(todayMoodProvider);
    return AppCard(
      accent: AppColors.mood,
      onTap: () => context.push(AppPaths.mood),
      semanticLabel: 'Mood',
      child: mood.when(
        loading: () => const ScanlineLoader(lines: 2),
        error: (e, _) => const Text('Mood couldn\'t be loaded.'),
        data: (e) => e == null ? const _MoodStandby() : _MoodToday(entry: e),
      ),
    );
  }
}

class _MoodStandby extends StatelessWidget {
  const _MoodStandby();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Hero(
              tag: 'life-mood-orb',
              child: MoodOrb(mood: null, size: 64),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('MOOD', style: hud.label(size: 11)),
                  const SizedBox(height: 2),
                  Text('No check-in yet today', style: t.titleMedium),
                  Text(
                    'How are you, right now? One tap is enough.',
                    style: t.bodySmall?.copyWith(color: hud.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        MoodPicker(
          value: null,
          size: 34,
          onChanged: (m) => showMoodCheckIn(context, initialMood: m),
        ),
      ],
    );
  }
}

class _MoodToday extends ConsumerWidget {
  const _MoodToday({required this.entry});
  final MoodEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final e = entry;
    final week = ref.watch(moodEntriesProvider(7)).value ?? const [];
    final today = LocalDates.key(ref.watch(clockProvider).now());
    final means = dailyMoodMeans(week.map(moodPointOf));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Hero(
              tag: 'life-mood-orb',
              child: MoodOrb(mood: e.mood.toDouble(), size: 64),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('MOOD', style: hud.label(size: 11)),
                  const SizedBox(height: 2),
                  Text(
                    '${moodLabels[e.mood]} · ${Fmt.time(e.recordedAt)}',
                    style: t.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: AppSpacing.md,
                    runSpacing: AppSpacing.xs,
                    children: [
                      MiniLevel(
                        label: 'ENERGY',
                        value: e.energy,
                        color: AppColors.calories,
                        valueLabel: energyLabels[e.energy],
                      ),
                      MiniLevel(
                        label: 'STRESS',
                        value: e.stress,
                        color: AppColors.info,
                        valueLabel: stressLabels[e.stress],
                      ),
                      MiniLevel(
                        label: 'SLEEP',
                        value: e.sleepQuality,
                        color: AppColors.sleep,
                        valueLabel: sleepQualityLabels[e.sleepQuality],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: _WeekMoodDots(means: means, today: today),
            ),
            HudButton.ghost(
              label: 'Update',
              compact: true,
              onPressed: () => showMoodCheckIn(context),
            ),
          ],
        ),
      ],
    );
  }
}

class _WeekMoodDots extends StatelessWidget {
  const _WeekMoodDots({required this.means, required this.today});
  final Map<String, double> means;
  final String today;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final days = [for (var i = 6; i >= 0; i--) LocalDates.addDays(today, -i)];
    final n = days.where(means.containsKey).length;
    return Semantics(
      label: 'Check-ins on $n of the last 7 days',
      excludeSemantics: true,
      child: Row(
        children: [
          for (final d in days)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: means[d] == null
                          ? hud.hairline.withValues(alpha: 0.12)
                          : moodColorAt(means[d]!),
                      boxShadow: means[d] == null
                          ? null
                          : [
                              BoxShadow(
                                color: moodColorAt(means[d]!)
                                    .withValues(alpha: 0.5 * hud.glowStrength),
                                blurRadius: 6,
                              ),
                            ],
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    weekdayLetter[LocalDates.parse(d).weekday - 1],
                    style: hud.label(
                      size: 9.5,
                      color: d == today ? hud.accentInk : hud.textMuted,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── Journal ─────────────────────────────────────────────────────────────────

class _JournalCard extends ConsumerWidget {
  const _JournalCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final written = ref.watch(journalWrittenTodayProvider);
    final now = ref.watch(clockProvider).now();
    final prompt = promptFor(now.difference(DateTime(2024)).inDays);
    final isWritten = written.value ?? false;
    return AppCard(
      onTap: () => context.push(AppPaths.journal),
      semanticLabel: 'Journal',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GlowIcon(
                isWritten ? Icons.auto_stories : Icons.menu_book_outlined,
                framed: true,
                size: 20,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('JOURNAL', style: hud.label(size: 11)),
                        const Spacer(),
                        const PrivacyBadge(label: 'PRIVATE'),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      written.when(
                        loading: () => '…',
                        error: (e, _) => 'Journal couldn\'t be loaded.',
                        data: (w) => w
                            ? 'Written today'
                            : 'Nothing written today — optional',
                      ),
                      style: t.titleSmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!isWritten) ...[
            const SizedBox(height: AppSpacing.md),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 2,
                    decoration: BoxDecoration(
                      color: hud.accent.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      prompt,
                      style: t.bodyMedium?.copyWith(
                        fontStyle: FontStyle.italic,
                        color: hud.text.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Align(
              alignment: Alignment.centerLeft,
              child: HudButton.secondary(
                label: 'Write a few lines',
                icon: Icons.edit_outlined,
                compact: true,
                onPressed: () => openJournalEditor(context, prompt: prompt),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Systems grid ────────────────────────────────────────────────────────────

class _SystemsGrid extends ConsumerWidget {
  const _SystemsGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(notificationPrefsProvider).value;
    final quiet = ref.watch(quietHoursProvider).value;
    final on = prefs?.values.where((p) => p.enabled).length;
    final reminderSub = [
      if (on != null) on == 0 ? 'ALL OFF' : '$on ON',
      if (quiet != null)
        'QUIET ${formatMinutes(quiet.start).substring(0, 2)}–'
            '${formatMinutes(quiet.end).substring(0, 2)}',
    ].join(' · ');
    final tiles = [
      _Tile(
        icon: Icons.event_note_outlined,
        label: 'Planner',
        sub: 'TOP 3 · FOCUS BLOCKS',
        onTap: () => context.push(AppPaths.planner),
      ),
      _Tile(
        icon: Icons.emoji_events_outlined,
        label: 'Competition prep',
        sub: 'PEAK WEEK',
        color: AppColors.competition,
        onTap: () => context.push(AppPaths.competition),
      ),
      _Tile(
        icon: Icons.insights_outlined,
        label: 'Reports',
        sub: 'WEEKLY DIGEST',
        onTap: () => context.push(AppPaths.reports),
      ),
      _Tile(
        icon: Icons.notifications_outlined,
        label: 'Reminders',
        sub: reminderSub.isEmpty ? 'NOTIFICATIONS' : reminderSub,
        onTap: () => context.push(AppPaths.notificationSettings),
      ),
    ];
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth > 600 ? 4 : 2;
            final w = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
            return Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                for (final tile in tiles) SizedBox(width: w, child: tile),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.md),
        _Tile(
          icon: Icons.settings_outlined,
          label: 'Settings',
          sub: 'PROFILE · PRIVACY · AI',
          horizontal: true,
          onTap: () => context.push(AppPaths.settings),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.label,
    required this.sub,
    required this.onTap,
    this.color,
    this.horizontal = false,
  });
  final IconData icon;
  final String label;
  final String sub;
  final VoidCallback onTap;
  final Color? color;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final glyph = GlowIcon(icon, color: color, framed: true, size: 18);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: t.titleSmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          sub,
          style: hud.label(size: 10),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
    return AppCard(
      onTap: onTap,
      semanticLabel: label,
      padding: const EdgeInsets.all(AppSpacing.md + 2),
      child: horizontal
          ? Row(
              children: [
                glyph,
                const SizedBox(width: AppSpacing.md),
                Expanded(child: text),
                Icon(Icons.chevron_right, color: hud.textMuted),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    glyph,
                    const Spacer(),
                    Icon(Icons.north_east, size: 14, color: hud.textMuted),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                text,
              ],
            ),
    );
  }
}
