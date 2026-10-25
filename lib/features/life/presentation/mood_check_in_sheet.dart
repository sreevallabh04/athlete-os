import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../data/mood_repository.dart';
import '../domain/crisis_detector.dart';
import '../domain/mood_stats.dart';
import 'widgets/life_widgets.dart';
import 'widgets/mood_orb.dart';

/// Opens the check-in sheet (optionally with a mood already chosen, e.g.
/// from a one-tap face on the Life hub). If the note suggested severe
/// distress, a calm support sheet follows.
Future<void> showMoodCheckIn(BuildContext context, {int? initialMood}) async {
  final distressed = await showHudBottomSheet<bool>(
    context,
    builder: (_) => MoodCheckInSheet(initialMood: initialMood),
  );
  if (distressed == true && context.mounted) {
    await showHudBottomSheet<void>(
      context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Flexible(child: SingleChildScrollView(child: SupportCard())),
          const SizedBox(height: AppSpacing.md),
          HudButton.ghost(label: 'Close', onPressed: () => Navigator.pop(ctx)),
        ],
      ),
    );
  }
}

/// Quick mood check-in. Pops with `true` when the note suggested severe
/// distress (so the caller can keep showing support), otherwise `false`.
class MoodCheckInSheet extends ConsumerStatefulWidget {
  const MoodCheckInSheet({super.key, this.initialMood});
  final int? initialMood;

  @override
  ConsumerState<MoodCheckInSheet> createState() => _MoodCheckInSheetState();
}

class _MoodCheckInSheetState extends ConsumerState<MoodCheckInSheet> {
  late int? _mood = widget.initialMood;
  int? _energy;
  int? _stress;
  int? _sleep;
  final _tags = <String>{};
  final _note = TextEditingController();
  bool _saving = false;
  double _scrub = 0;

  @override
  void initState() {
    super.initState();
    _note.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _setMood(int m) {
    if (m == _mood) return;
    setState(() => _mood = m);
  }

  // Swipe across the orb to scrub the mood, one detent per ~32 px.
  void _onScrub(DragUpdateDetails d) {
    _scrub += d.delta.dx;
    const step = 32.0;
    if (_scrub.abs() < step) return;
    final dir = _scrub.sign.toInt();
    _scrub = 0;
    final next = ((_mood ?? 3) + dir).clamp(1, 5);
    if (next != _mood) {
      Haptics.selection();
      _setMood(next);
    }
  }

  Future<void> _save() async {
    final mood = _mood;
    if (mood == null) return;
    setState(() => _saving = true);
    await ref
        .read(moodRepositoryProvider)
        .add(
          MoodInput(
            mood: mood,
            energy: _energy,
            stress: _stress,
            sleepQuality: _sleep,
            tags: _tags.toList(),
            note: _note.text,
          ),
        );
    Haptics.success();
    if (mounted) Navigator.of(context).pop(detectsSevereDistress(_note.text));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final distress = detectsSevereDistress(_note.text);
    final m = _mood;
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [
        Text(
          'How are you feeling?',
          style: t.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.md),
        Center(
          child: GestureDetector(
            onHorizontalDragStart: (_) => _scrub = 0,
            onHorizontalDragUpdate: _onScrub,
            child: MoodOrb(mood: m?.toDouble(), size: 136),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        AnimatedSwitcher(
          duration: AppMotion.short,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: ScaleTransition(
              scale: Tween(begin: 0.9, end: 1.0).animate(a),
              child: child,
            ),
          ),
          child: Text(
            m == null
                ? 'TAP A FACE · OR SWIPE THE ORB'
                : moodLabels[m]!.toUpperCase(),
            key: ValueKey(m),
            textAlign: TextAlign.center,
            style: hud.label(
              size: m == null ? 11 : 15,
              color: m == null
                  ? hud.textMuted
                  : (hud.isDark ? moodColor(m) : hud.text),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        MoodPicker(value: m, onChanged: _setMood, size: 36),
        const SizedBox(height: AppSpacing.lg),
        GlassPanel(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.xs,
          ),
          child: Column(
            children: [
              ScaleSelector(
                label: 'Energy',
                icon: Icons.bolt_rounded,
                labels: energyLabels,
                value: _energy,
                onChanged: (v) => setState(() => _energy = v),
                color: AppColors.calories,
              ),
              const SizedBox(height: AppSpacing.sm),
              ScaleSelector(
                label: 'Stress',
                icon: Icons.waves_rounded,
                labels: stressLabels,
                value: _stress,
                onChanged: (v) => setState(() => _stress = v),
                color: AppColors.info,
              ),
              const SizedBox(height: AppSpacing.sm),
              ScaleSelector(
                label: 'Sleep last night',
                icon: Icons.bedtime_rounded,
                labels: sleepQualityLabels,
                value: _sleep,
                onChanged: (v) => setState(() => _sleep = v),
                color: AppColors.sleep,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('EMOTIONS · OPTIONAL', style: hud.label(size: 11)),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.xs + 2,
          runSpacing: AppSpacing.xs + 2,
          children: [
            for (final tag in emotionTags)
              LifePill(
                label: tag,
                selected: _tags.contains(tag),
                color: AppColors.mood,
                onTap: () => setState(
                  () =>
                      _tags.contains(tag) ? _tags.remove(tag) : _tags.add(tag),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        TextField(
          controller: _note,
          minLines: 2,
          maxLines: 5,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Note (optional)',
            hintText: 'Anything on your mind?',
          ),
        ),
        AnimatedSize(
          duration: AppMotion.medium,
          curve: AppMotion.standard,
          child: distress
              ? const Padding(
                  padding: EdgeInsets.only(top: AppSpacing.md),
                  child: SupportCard(),
                )
              : const SizedBox(width: double.infinity),
        ),
        const SizedBox(height: AppSpacing.lg),
        HudButton(
          label: m == null ? 'Choose a mood to save' : 'Save check-in',
          icon: m == null ? null : Icons.check_rounded,
          expand: true,
          loading: _saving,
          onPressed: m == null || _saving ? null : _save,
        ),
        const SizedBox(height: AppSpacing.md),
        const Center(child: PrivacyBadge(label: 'STORED ONLY ON THIS DEVICE')),
      ],
    );
  }
}
