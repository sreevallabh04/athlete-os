import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';
import '../../agent/coach_controller.dart';
import 'markdown_lite.dart';

// ---------------------------------------------------------------------------
// User line
// ---------------------------------------------------------------------------

/// The user's words: right-aligned glass with a cyan edge light.
class UserLine extends StatelessWidget {
  const UserLine(this.text, {super.key, this.animate = false});
  final String text;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.8;
    final bubble = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: CustomPaint(
        painter: GlassPainter(
          hud: hud,
          radius: 18,
          accent: hud.accent,
          borderStrength: 0.9,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 11, 16, 12),
          child: Text(text, style: t.bodyLarge?.copyWith(height: 1.4)),
        ),
      ),
    );
    return Semantics(
      label: 'You said',
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.lg, bottom: 6),
        child: Align(
          alignment: Alignment.centerRight,
          child: animate
              ? Entrance(
                  offset: const Offset(0, 10),
                  fromScale: 0.96,
                  duration: AppMotion.medium,
                  child: bubble,
                )
              : bubble,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// JARVIS reply with word-by-word reveal
// ---------------------------------------------------------------------------

/// Words appear one by one (~32 ms per word, capped at 2.4 s); tap to
/// reveal everything at once. Reduced motion shows the final text.
class RevealController {
  static Duration durationFor(String text) {
    final words = MarkdownLite.wordCount(text);
    return Duration(milliseconds: (words * 32).clamp(280, 2400));
  }
}

class JarvisReply extends StatefulWidget {
  const JarvisReply({
    super.key,
    required this.text,
    this.sources = const [],
    this.model,
    this.animate = false,
    this.onSpeak,
    this.eyebrow,
    this.footer,
  });

  final String text;
  final List<String> sources;
  final String? model;

  /// Reveal word by word (new answers only).
  final bool animate;
  final VoidCallback? onSpeak;

  /// Replaces the default "JARVIS" header label.
  final String? eyebrow;
  final Widget? footer;

  @override
  State<JarvisReply> createState() => _JarvisReplyState();
}

class _JarvisReplyState extends State<JarvisReply>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: RevealController.durationFor(widget.text),
    value: widget.animate ? 0 : 1,
  );
  late final int _words = MarkdownLite.wordCount(widget.text);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _c.value = 1;
    } else if (widget.animate && _c.value == 0 && !_c.isAnimating) {
      unawaited(_c.forward());
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _skip() {
    if (_c.isAnimating) {
      Haptics.selection();
      _c.value = 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    final body = t.bodyLarge?.copyWith(height: 1.5, color: hud.text);
    return Semantics(
      label: 'JARVIS said',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _skip,
        onLongPress: () async {
          await Clipboard.setData(ClipboardData(text: widget.text));
          Haptics.medium();
          if (context.mounted) {
            ScaffoldMessenger.maybeOf(context)
                ?.showSnackBar(const SnackBar(content: Text('Answer copied')));
          }
        },
        child: Padding(
          padding: const EdgeInsets.only(top: AppSpacing.md, bottom: 4),
          child: CustomPaint(
            painter: _RulePainter(hud.accent, hud.glowStrength),
            child: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  final reveal = _c.value >= 1 ? null : _c.value * (_words + 3);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _ReplyHeader(
                        label: widget.eyebrow ?? 'JARVIS',
                        live: _c.isAnimating,
                        onSpeak: widget.onSpeak,
                      ),
                      const SizedBox(height: 6),
                      MarkdownLite(
                        widget.text,
                        style: body,
                        reveal: reveal,
                        accent: hud.accent,
                        boldColor: hud.isDark
                            ? Color.lerp(hud.accent, Colors.white, 0.35)
                            : hud.accentInk,
                      ),
                      AnimatedOpacity(
                        opacity: _c.value >= 1 ? 1 : 0,
                        duration: AppMotion.medium,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (widget.sources.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final s in widget.sources.take(4))
                                      _SourceTag(s),
                                  ],
                                ),
                              ),
                            ?widget.footer,
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Luminous vertical rule on the left of a reply: bright at the top
/// (where JARVIS's marker sits), fading down the answer.
class _RulePainter extends CustomPainter {
  const _RulePainter(this.color, this.glow);
  final Color color;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    const dot = Offset(3.75, 11);
    canvas.drawCircle(
      dot,
      6,
      Paint()
        ..color = color.withValues(alpha: 0.45 * glow)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawCircle(dot, 3.2, Paint()..color = color);
    canvas.drawCircle(
      dot,
      1.4,
      Paint()..color = Colors.white.withValues(alpha: 0.9),
    );
    final rect = Rect.fromLTWH(3, 22, 1.5, size.height - 26);
    if (rect.height <= 0) return;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.55 * (0.5 + 0.5 * glow)),
            color.withValues(alpha: 0.0),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RulePainter old) =>
      old.color != color || old.glow != glow;
}

class _ReplyHeader extends StatelessWidget {
  const _ReplyHeader({required this.label, required this.live, this.onSpeak});
  final String label;
  final bool live;
  final VoidCallback? onSpeak;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    return SizedBox(
      height: 22,
      child: Row(
        children: [
          Text(label, style: hud.label(size: 12.5, color: hud.accentInk)),
          if (live) ...[
            const SizedBox(width: 8),
            Text('TRANSMITTING', style: hud.mono(size: 9.5)),
          ],
          const Spacer(),
          if (onSpeak != null)
            Semantics(
              button: true,
              label: 'Read aloud',
              excludeSemantics: true,
              onTap: onSpeak,
              child: PressableScale(
                onTap: onSpeak,
                haptic: PressHaptic.selection,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(
                    Icons.graphic_eq_rounded,
                    size: 18,
                    color: hud.textMuted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SourceTag extends StatelessWidget {
  const _SourceTag(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.xs),
        border: Border.all(color: hud.hairline.withValues(alpha: 0.2)),
        color: hud.text.withValues(alpha: 0.03),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.link_rounded, size: 11, color: hud.textMuted),
          const SizedBox(width: 4),
          Text(label, style: hud.mono(size: 10.5)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Subsystem trace (tool activity)
// ---------------------------------------------------------------------------

/// Cinematic verb for each tool ("Scanning nutrition log").
const subsystemVerbs = <String, String>{
  'get_today_dashboard': 'Compiling daily status',
  'get_nutrition_summary': 'Scanning nutrition log',
  'search_food_database': 'Searching food database',
  'log_food': 'Logging meal',
  'update_food_entry': 'Amending food entry',
  'get_water_summary': 'Reading hydration log',
  'log_water': 'Logging water',
  'get_steps_summary': 'Reading Health Connect',
  'get_workout_history': 'Pulling training history',
  'get_strength_progress': 'Analysing strength curve',
  'get_running_activities': 'Reading cardio log',
  'get_strava_activities': 'Strava · restricted',
  'analyze_strava_activity': 'Strava · restricted',
  'get_calendar_events': 'Checking calendar',
  'suggest_schedule': 'Computing free slots',
  'get_habit_summary': 'Checking habit streaks',
  'log_mood': 'Recording check-in',
  'get_journal_summary': 'Reading journal excerpts',
  'get_competition_countdown': 'Competition countdown',
  'get_weekly_report': 'Compiling weekly report',
  'get_profile_and_goals': 'Loading profile & targets',
  'remember_preference': 'Proposing a memory',
  'record_recommendation': 'Filing recommendation',
};

/// "Scanning nutrition log · Oct 25" from the tool name and its chip label.
String subsystemLabel(ToolChipEntry e) {
  final verb = subsystemVerbs[e.toolName];
  if (verb == null) return e.label;
  final i = e.label.indexOf(' · ');
  if (i < 0 || verb.contains(' · ')) return verb;
  return '$verb${e.label.substring(i)}';
}

/// A block of subsystem lines for consecutive tool calls.
class SubsystemTrace extends StatelessWidget {
  const SubsystemTrace({super.key, required this.entries, this.trailing});
  final List<ToolChipEntry> entries;

  /// Extra live line (e.g. "Consulting Gemini").
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md, left: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in entries)
            SubsystemLine(
              key: ValueKey('sub-${e.toolCallId}'),
              label: subsystemLabel(e),
              status: e.status,
              isWrite: e.isWrite,
            ),
          ?trailing,
        ],
      ),
    );
  }
}

class SubsystemLine extends StatelessWidget {
  const SubsystemLine({
    super.key,
    required this.label,
    required this.status,
    this.isWrite = false,
    this.trailingText,
  });

  final String label;
  final ToolChipStatus status;
  final bool isWrite;
  final String? trailingText;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final (Color color, String tag) = switch (status) {
      ToolChipStatus.running => (hud.accent, 'LIVE'),
      ToolChipStatus.ok => (
        isWrite ? AppColors.success : hud.textMuted,
        isWrite ? 'DONE' : 'OK',
      ),
      ToolChipStatus.error => (AppColors.danger, 'FAULT'),
      ToolChipStatus.pending => (AppColors.warning, 'HOLD'),
      ToolChipStatus.rejected => (hud.textMuted, 'SKIPPED'),
      ToolChipStatus.consent => (AppColors.warning, 'LOCKED'),
    };
    final running = status == ToolChipStatus.running;
    final glyph = running
        ? HudSpinner(size: 12, color: hud.accent)
        : Icon(
            switch (status) {
              ToolChipStatus.ok => Icons.check_rounded,
              ToolChipStatus.error => Icons.priority_high_rounded,
              ToolChipStatus.pending => Icons.pause_rounded,
              ToolChipStatus.rejected => Icons.block_rounded,
              ToolChipStatus.consent => Icons.lock_outline_rounded,
              ToolChipStatus.running => Icons.sync,
            },
            size: 13,
            color: color,
          );
    return Semantics(
      label: '$label, ${tag.toLowerCase()}',
      excludeSemantics: true,
      child: Entrance(
        offset: const Offset(-10, 0),
        duration: AppMotion.medium,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(width: 16, child: Center(child: glyph)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: hud.mono(
                    size: 11.5,
                    color: running ? hud.text : hud.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                trailingText ?? tag,
                style: hud.mono(size: 10, color: color.withValues(alpha: 0.9)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The optimistic "Consulting Gemini · 00:07" line with a live timer. After
/// 8 s it explains the wait, so latency feels intentional, not broken.
class ConsultingLine extends StatefulWidget {
  const ConsultingLine({
    super.key,
    required this.since,
    required this.provider,
    this.label,
  });

  final DateTime? since;
  final String provider;

  /// Overrides "Consulting {provider}".
  final String? label;

  @override
  State<ConsultingLine> createState() => _ConsultingLineState();
}

class _ConsultingLineState extends State<ConsultingLine> {
  Timer? _timer;
  late final DateTime _start = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final s = DateTime.now().difference(_start).inSeconds;
    final clock =
        '${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SubsystemLine(
          label: widget.label ?? 'Consulting ${widget.provider}',
          status: ToolChipStatus.running,
          trailingText: clock,
        ),
        AnimatedSize(
          duration: AppMotion.medium,
          curve: AppMotion.emphasizedDecelerate,
          child: s >= 8
              ? Padding(
                  padding: const EdgeInsets.only(left: 24, top: 2),
                  child: Text(
                    s >= 30
                        ? 'Still working. If this stalls, you can stop and retry on the fast provider.'
                        : 'Deep reasoning in progress — this model can take up to ~25 s.',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: hud.textMuted),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
