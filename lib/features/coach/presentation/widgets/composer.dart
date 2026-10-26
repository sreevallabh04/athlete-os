import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/widgets.dart';

/// Round glass action used by the composer (mic, send, stop).
class HudIconAction extends StatelessWidget {
  const HudIconAction({
    super.key,
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
    this.filled = false,
    this.color,
    this.size = 44,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onTap;
  final bool filled;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final c = color ?? hud.accent;
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: PressableScale(
        onTap: onTap,
        pressedScale: 0.9,
        haptic: PressHaptic.light,
        child: AnimatedContainer(
          duration: AppMotion.short,
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: filled && enabled
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color.lerp(c, Colors.white, 0.2)!, c],
                  )
                : null,
            color: filled && enabled
                ? null
                : hud.text.withValues(alpha: enabled ? 0.06 : 0.03),
            border: Border.all(
              color: filled && enabled
                  ? c
                  : hud.hairline.withValues(alpha: enabled ? 0.22 : 0.1),
            ),
            boxShadow: filled && enabled
                ? AppGlows.soft(c, strength: hud.glowStrength)
                : null,
          ),
          child: Icon(
            icon,
            size: size * 0.48,
            color: filled && enabled
                ? const Color(0xFF02141C)
                : enabled
                ? hud.text
                : hud.textMuted.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

/// Push-to-talk microphone: tap toggles listening; press-and-hold talks
/// until release. Pulses with the mic level while live.
class MicButton extends StatefulWidget {
  const MicButton({
    super.key,
    required this.listening,
    required this.enabled,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
    this.level,
  });

  final bool listening;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;
  final Stream<double>? level;

  @override
  State<MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<MicButton> {
  bool _holding = false;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final live = widget.listening;
    final c = hud.accent;
    final core = AnimatedContainer(
      duration: AppMotion.medium,
      curve: AppMotion.emphasizedDecelerate,
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: live
            ? RadialGradient(colors: [Color.lerp(c, Colors.white, 0.35)!, c])
            : null,
        color: live ? null : c.withValues(alpha: widget.enabled ? 0.12 : 0.04),
        border: Border.all(
          color: c.withValues(alpha: widget.enabled ? (live ? 1 : 0.55) : 0.2),
        ),
        boxShadow: live ? AppGlows.strong(c, strength: hud.glowStrength) : null,
      ),
      child: Icon(
        live ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
        size: 22,
        color: live
            ? const Color(0xFF02141C)
            : (widget.enabled ? c : hud.textMuted),
      ),
    );
    return Semantics(
      button: true,
      enabled: widget.enabled,
      toggled: live,
      label: live ? 'Stop listening' : 'Talk to JARVIS',
      hint: 'Tap to toggle, or press and hold to talk',
      excludeSemantics: true,
      onTap: widget.enabled ? widget.onTap : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        onLongPressStart: widget.enabled
            ? (_) {
                _holding = true;
                widget.onHoldStart();
              }
            : null,
        onLongPressEnd: widget.enabled
            ? (_) {
                if (!_holding) return;
                _holding = false;
                widget.onHoldEnd();
              }
            : null,
        child: SizedBox.square(
          dimension: 48,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              if (live && widget.level != null)
                StreamBuilder<double>(
                  stream: widget.level,
                  builder: (context, snap) {
                    final l = snap.data ?? 0;
                    return Container(
                      width: 46 + 18 * l,
                      height: 46 + 18 * l,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c.withValues(alpha: 0.25 + 0.5 * l),
                          width: 1.5,
                        ),
                      ),
                    );
                  },
                ),
              AnimatedScale(
                scale: _holding ? 1.12 : 1,
                duration: AppMotion.short,
                child: core,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The floating glass command bar: mic · text field · send/stop.
class CoachComposer extends StatelessWidget {
  const CoachComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.busy,
    required this.listening,
    required this.voiceEnabled,
    required this.partial,
    required this.onSend,
    required this.onStop,
    required this.onMicTap,
    required this.onMicHoldStart,
    required this.onMicHoldEnd,
    this.level,
    this.hint = 'Ask JARVIS…',
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final bool busy;
  final bool listening;
  final bool voiceEnabled;
  final String partial;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onMicTap;
  final VoidCallback onMicHoldStart;
  final VoidCallback onMicHoldEnd;
  final Stream<double>? level;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    final radius = BorderRadius.circular(AppRadii.dock);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: AnimatedContainer(
          duration: AppMotion.medium,
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          decoration: BoxDecoration(
            borderRadius: radius,
            color: hud.glassFillStrong,
            border: Border.all(
              color: listening
                  ? hud.accent.withValues(alpha: 0.8)
                  : hud.hairline.withValues(alpha: hud.isDark ? 0.2 : 0.35),
            ),
            boxShadow: listening
                ? AppGlows.soft(hud.accent, strength: hud.glowStrength)
                : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              MicButton(
                listening: listening,
                enabled: enabled && voiceEnabled && !busy,
                level: level,
                onTap: onMicTap,
                onHoldStart: onMicHoldStart,
                onHoldEnd: onMicHoldEnd,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: listening
                      ? _LiveTranscript(text: partial)
                      : TextField(
                          controller: controller,
                          focusNode: focusNode,
                          minLines: 1,
                          maxLines: 5,
                          maxLength: 4000,
                          enabled: enabled,
                          textCapitalization: TextCapitalization.sentences,
                          textInputAction: TextInputAction.send,
                          style: t.bodyLarge,
                          cursorColor: hud.accent,
                          decoration: InputDecoration(
                            hintText: hint,
                            counterText: '',
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 12,
                            ),
                          ),
                          onSubmitted: enabled && !busy
                              ? (_) => onSend()
                              : null,
                        ),
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: busy
                    ? HudIconAction(
                        key: const Key('coach_stop'),
                        icon: Icons.stop_rounded,
                        semanticLabel: 'Stop',
                        onTap: onStop,
                        color: AppColors.danger,
                      )
                    : ValueListenableBuilder<TextEditingValue>(
                        valueListenable: controller,
                        builder: (context, v, _) => HudIconAction(
                          key: const Key('coach_send'),
                          icon: Icons.arrow_upward_rounded,
                          semanticLabel: 'Send',
                          filled: v.text.trim().isNotEmpty,
                          onTap: enabled && !listening ? onSend : null,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveTranscript extends StatelessWidget {
  const _LiveTranscript({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: text.isEmpty
          ? Row(
              children: [
                const _Dots(),
                const SizedBox(width: 10),
                Text(
                  'Listening',
                  style: hud.label(size: 13, color: hud.accentInk),
                ),
              ],
            )
          : Text(
              text,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: t.bodyLarge?.copyWith(fontStyle: FontStyle.italic),
            ),
    );
  }
}

/// Three dots breathing in sequence.
class _Dots extends StatefulWidget {
  const _Dots();
  @override
  State<_Dots> createState() => _DotsState();
}

class _DotsState extends State<_Dots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!AppMotion.reduced(context) && !_c.isAnimating) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = HudTheme.of(context).accent;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 5,
              height: 5,
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.withValues(
                  alpha:
                      0.3 +
                      0.7 *
                          (0.5 +
                              0.5 * math.sin((_c.value - i / 3) * 2 * math.pi)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
