import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../assistant/data/assistant_platform.dart'
    show assistantPlatformProvider;
import '../agent/briefing.dart';
import '../agent/coach_controller.dart';
import '../data/ai_backend.dart';
import '../data/ai_status.dart';
import '../voice/speech_ports.dart';
import '../voice/voice_controller.dart';
import '../voice/voice_settings.dart';
import 'coach_telemetry.dart';
import 'voice_settings_sheet.dart';
import 'widgets/chat_widgets.dart';
import 'widgets/composer.dart';
import 'widgets/history_panel.dart';
import 'widgets/jarvis_core.dart';
import 'widgets/quick_commands.dart';
import 'widgets/transcript.dart';

/// The Coach's live link status (provider, fallback, offline).
final coachLinkProvider = Provider.autoDispose<CoachLink>((ref) {
  final backend = ref.watch(aiBackendStateProvider);
  final coach = ref.watch(coachControllerProvider);
  final status = backend == AiBackendState.ready
      ? ref.watch(aiStatusProvider)
      : const AsyncData<Map<String, Object?>?>(null);
  return deriveCoachLink(
    backend: backend,
    status: status.value,
    statusLoading: status.isLoading,
    statusFailed: status.hasError,
    lastProvider: coach.lastProvider,
    fallbackUsed: coach.fallbackUsed,
    lastLatency: coach.lastLatency,
    lastErrorCode: coach.error?.code,
  );
});

/// JARVIS: a full-screen, voice-first assistant surface.
///
/// Empty session: a large reactor orb with a time-aware greeting, live
/// readouts and context-aware quick commands. Once a session starts, the
/// orb glides up into the header and the HUD transcript takes over.
class CoachScreen extends ConsumerStatefulWidget {
  const CoachScreen({super.key, this.initialPrompt, this.listen = false});

  /// Prefills the composer (from `/coach?prompt=...`). Never auto-sent.
  final String? initialPrompt;

  /// Start listening on arrival (`/coach?listen=1`, the "Ask JARVIS"
  /// launcher shortcut). Goes through the same mic explainer and permission
  /// flow as a tap on the mic; does nothing while the AI core is offline.
  final bool listen;

  @override
  ConsumerState<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends ConsumerState<CoachScreen> {
  late final TextEditingController _input;
  final _focus = FocusNode();
  final _scroll = ScrollController();

  /// Entries at index ≥ this animate in (new this visit); older ones are
  /// shown as they are.
  int _animateFrom = 1 << 30;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: _clean(widget.initialPrompt));
    final s = ref.read(coachControllerProvider);
    _animateFrom = s.entries.length;
    ref.listenManual(coachControllerProvider, _onCoach);
    ref.listenManual(voiceControllerProvider, _onVoice);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.listen ? _listenOnArrival() : _maybeWake(),
    );
  }

  @override
  void didUpdateWidget(CoachScreen old) {
    super.didUpdateWidget(old);
    final p = _clean(widget.initialPrompt);
    if (widget.initialPrompt != old.initialPrompt && p.isNotEmpty) {
      _input.text = p;
    }
    if (widget.listen && !old.listen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _listenOnArrival());
    }
  }

  static String _clean(String? p) {
    final s = (p ?? '').trim();
    return s.length > 1000 ? s.substring(0, 1000) : s;
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Reactions: haptics on every state change, auto-speak
  // -------------------------------------------------------------------------

  void _onCoach(CoachState? prev, CoachState next) {
    if (prev == null) return;
    if (next.conversationId != prev.conversationId) {
      if (prev.conversationId == null && next.entries.length <= 1) {
        // A new session just started: everything in it is new.
        _animateFrom = 0;
      } else {
        // Opened another session: show it as it is.
        _animateFrom = next.conversationId == null ? 0 : next.entries.length;
      }
    }
    if (prev.phase != next.phase && next.phase != CoachPhase.idle) {
      Haptics.selection();
    }
    if (prev.pending == null && next.pending != null) Haptics.medium();
    if (prev.error == null && next.error != null) Haptics.warning();
    if (next.replySerial != prev.replySerial) {
      Haptics.success();
      _autoSpeak(next);
    }
  }

  void _onVoice(VoiceState? prev, VoiceState next) {
    if (prev == null) return;
    if (prev.phase != next.phase) {
      switch (next.phase) {
        case VoicePhase.listening:
          Haptics.medium();
        case VoicePhase.speaking:
          Haptics.light();
        case VoicePhase.idle:
          if (prev.phase == VoicePhase.listening) Haptics.light();
        case VoicePhase.starting:
          break;
      }
    }
    if (next.message != null && next.message != prev.message) {
      _snack(next.message!);
    }
    if (next.issue != null && next.issue != prev.issue) {
      unawaited(_explainIssue(next.issue!));
    }
  }

  VoiceSettings get _voiceSettings =>
      ref.read(voiceSettingsProvider).value ?? const VoiceSettings();

  String? _lastReplyText(CoachState s) {
    for (final e in s.entries.reversed) {
      if (e is AssistantTextEntry) return e.text;
      if (e is BriefingEntry) return e.text;
      if (e is UserTextEntry) return null;
    }
    return null;
  }

  void _autoSpeak(CoachState s) {
    final v = _voiceSettings;
    if (!v.enabled) return;
    final speak =
        v.autoSpeak == AutoSpeak.always ||
        (v.autoSpeak == AutoSpeak.voice && s.voiceTurn);
    if (!speak) return;
    // Entries reload right after the serial bumps; read them next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final text = _lastReplyText(ref.read(coachControllerProvider));
      if (text != null) {
        unawaited(ref.read(voiceControllerProvider.notifier).speak(text, v));
      }
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  Future<void> _send([String? text, bool viaVoice = false]) async {
    final value = (text ?? _input.text).trim();
    if (value.isEmpty) return;
    final action = matchVoiceCommand(value);
    _input.clear();
    _focus.unfocus();
    final c = ref.read(coachControllerProvider.notifier);
    if (action == QuickAction.brief) {
      await c.brief(BriefingMode.morning, viaVoice: viaVoice);
    } else if (action == QuickAction.review) {
      await c.brief(BriefingMode.evening, viaVoice: viaVoice);
    } else {
      await c.send(value, viaVoice: viaVoice);
    }
  }

  Future<void> _runCommand(QuickCommand cmd) async {
    final c = ref.read(coachControllerProvider.notifier);
    switch (cmd.action) {
      case QuickAction.brief:
        await c.brief(BriefingMode.morning);
      case QuickAction.review:
        await c.brief(BriefingMode.evening);
      case QuickAction.prompt:
        if (ref.read(aiBackendStateProvider) == AiBackendState.ready) {
          await _send(cmd.text);
        } else {
          _input.text = cmd.text;
          Haptics.warning();
          _snack('The AI core is offline. Briefings still work locally.');
        }
    }
  }

  Future<void> _maybeWake() async {
    if (!mounted) return;
    final v = await ref.read(voiceSettingsRepositoryProvider).load();
    if (!mounted || !v.enabled || !v.wakeOnOpen) return;
    if (ref.read(aiBackendStateProvider) != AiBackendState.ready) return;
    final voice = ref.read(voiceControllerProvider.notifier);
    if (!await voice.hasPermission()) return; // never prompt unasked
    await _listen();
  }

  /// `/coach?listen=1`: the person explicitly asked to talk, so this behaves
  /// like a mic tap (explainer first, then Android's permission prompt).
  Future<void> _listenOnArrival() async {
    if (!mounted) return;
    final vs = ref.read(voiceControllerProvider);
    if (vs.listening || vs.phase == VoicePhase.starting) return;
    if (ref.read(aiBackendStateProvider) != AiBackendState.ready) {
      _snack('The AI core is offline, so voice is unavailable. Typing works.');
      return;
    }
    final v = await ref.read(voiceSettingsRepositoryProvider).load();
    if (!mounted) return;
    if (!v.enabled) {
      _snack('Voice is switched off in voice settings.');
      return;
    }
    if (ref.read(coachControllerProvider).busy) return;
    if (!await _ensureMicExplained(v)) return;
    await _listen();
  }

  /// First tap ever: explain why the mic is needed before Android asks.
  Future<bool> _ensureMicExplained([VoiceSettings? loaded]) async {
    final v = loaded ?? _voiceSettings;
    if (v.micExplained) return true;
    final voice = ref.read(voiceControllerProvider.notifier);
    if (await voice.hasPermission()) return true;
    if (!mounted) return false;
    final ok = await showHudBottomSheet<bool>(
      context,
      title: 'Talk to JARVIS',
      builder: (context) => const _MicExplainer(),
    );
    if (ok != true) return false;
    await ref
        .read(voiceSettingsRepositoryProvider)
        .update((s) => s.copyWith(micExplained: true));
    return true;
  }

  Future<void> _explainIssue(RecognizerIssue issue) async {
    if (!mounted) return;
    ref.read(voiceControllerProvider.notifier).clearMessage();
    await showHudBottomSheet<void>(
      context,
      title: issue == RecognizerIssue.permissionDenied
          ? 'Microphone is off'
          : 'No speech recogniser',
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            issue == RecognizerIssue.permissionDenied
                ? 'Android is blocking the microphone for Athlete OS. To talk '
                      'to JARVIS, open Settings › Apps › Athlete OS › '
                      'Permissions › Microphone and allow it. Typing still '
                      'works.'
                : 'This phone has no speech recognition service available. '
                      'Install or enable "Speech Recognition & Synthesis from '
                      'Google" (or another recogniser), then try again. '
                      'Typing still works.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.lg),
          if (issue == RecognizerIssue.permissionDenied) ...[
            HudButton(
              label: 'Open app settings',
              icon: Icons.open_in_new_rounded,
              expand: true,
              onPressed: () {
                Navigator.pop(context);
                unawaited(
                  ref.read(assistantPlatformProvider).openAppDetailsSettings(),
                );
              },
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          HudButton.ghost(
            label: 'Understood',
            expand: true,
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Future<void> _listen() async {
    final voice = ref.read(voiceControllerProvider.notifier);
    await voice.startListening(
      preferOffline: _voiceSettings.preferOffline,
      onFinal: (text) => unawaited(_send(text, true)),
    );
  }

  Future<void> _onMicTap() async {
    final vs = ref.read(voiceControllerProvider);
    final voice = ref.read(voiceControllerProvider.notifier);
    if (vs.listening || vs.phase == VoicePhase.starting) {
      await voice.stopListening();
      return;
    }
    if (!await _ensureMicExplained()) return;
    await _listen();
  }

  Future<void> _onMicHoldStart() async {
    if (!_voiceSettings.micExplained &&
        !await ref.read(voiceControllerProvider.notifier).hasPermission()) {
      // First use: explain instead of grabbing the mic mid-gesture.
      await _onMicTap();
      return;
    }
    await _listen();
  }

  Future<void> _onOrbTap() async {
    final vs = ref.read(voiceControllerProvider);
    final voice = ref.read(voiceControllerProvider.notifier);
    if (vs.speaking) {
      await voice.stopSpeaking();
    } else if (vs.listening) {
      await voice.stopListening();
    } else if (ref.read(aiBackendStateProvider) == AiBackendState.ready &&
        _voiceSettings.enabled &&
        !ref.read(coachControllerProvider).busy) {
      await _onMicTap();
    } else {
      Haptics.light();
    }
  }

  void _openMenu() {
    showHudBottomSheet<void>(
      context,
      title: 'Systems',
      builder: (sheet) {
        Widget item(IconData icon, String title, String sub, VoidCallback on) =>
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: GlowIcon(icon, size: 20, framed: true),
              title: Text(title),
              subtitle: Text(sub),
              onTap: () {
                Navigator.pop(sheet);
                on();
              },
            );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            item(
              Icons.graphic_eq_rounded,
              'Voice',
              'Push-to-talk, spoken replies, voice and rate',
              () => showVoiceSettingsSheet(context),
            ),
            item(
              Icons.psychology_alt_outlined,
              'Coach memory',
              'What JARVIS remembers about you',
              () => context.push(AppPaths.aiMemory),
            ),
            item(
              Icons.receipt_long_outlined,
              'AI activity log',
              'Every tool call and recommendation',
              () => context.push(AppPaths.aiHistory),
            ),
            item(
              Icons.hub_outlined,
              'AI settings',
              'Providers, budget, persona, consent',
              () => context.push(AppPaths.aiSettings),
            ),
          ],
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  OrbState _orbState(CoachState s, VoiceState v) {
    if (v.listening || v.phase == VoicePhase.starting) {
      return OrbState.listening;
    }
    if (v.speaking) return OrbState.speaking;
    if (s.busy) return OrbState.thinking;
    return OrbState.idle;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(coachControllerProvider);
    final backendState = ref.watch(aiBackendStateProvider);
    final link = ref.watch(coachLinkProvider);
    final voice = ref.watch(voiceControllerProvider);
    final voiceCtl = ref.read(voiceControllerProvider.notifier);
    final voiceSettings =
        ref.watch(voiceSettingsProvider).value ?? const VoiceSettings();
    final telemetry = ref.watch(coachTelemetryProvider).value;
    final controller = ref.read(coachControllerProvider.notifier);
    final ready = backendState == AiBackendState.ready;
    final docked = state.entries.isNotEmpty || state.busy;
    final orbState = _orbState(state, voice);
    final mq = MediaQuery.of(context);
    final bottomInset = math.max(mq.viewInsets.bottom, mq.padding.bottom);
    final now = ref.watch(clockProvider).now();
    final commands = quickCommands(telemetry?.quick ?? QuickContext(now: now));
    final voiceOk = ready && voiceSettings.enabled;

    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => _Stage(
                    docked: docked,
                    header: _Header(
                      link: link,
                      voiceStatus: voice.listening
                          ? 'Listening · tap to send'
                          : voice.speaking
                          ? 'Speaking · tap to stop'
                          : null,
                      onHistory: () => showConversationHistory(context),
                      onNew: state.busy ? null : controller.newConversation,
                      onMenu: _openMenu,
                    ),
                    orb: _AnimatedCore(
                      docked: docked,
                      box: box,
                      state: orbState,
                      level: voiceCtl.levels,
                      speakProgress: voice.speakProgress,
                      wordTick: voice.wordTick,
                      onTap: () => unawaited(_onOrbTap()),
                      onHoldStart: voiceOk
                          ? () => unawaited(_onMicHoldStart())
                          : null,
                      onHoldEnd: voiceOk
                          ? () => unawaited(voiceCtl.stopListening())
                          : null,
                    ),
                    hero: _Hero(
                      now: now,
                      telemetry: telemetry,
                      link: link,
                      backendState: backendState,
                      listening: voice.listening,
                      partial: voice.partial,
                    ),
                    transcript: _Transcript(
                      state: state,
                      animateFrom: _animateFrom,
                      link: link,
                      scroll: _scroll,
                      onRetry: () => unawaited(controller.retry()),
                      onFastRetry: () =>
                          unawaited(controller.retry(fast: true)),
                      onSettings: () => context.push(AppPaths.aiSettings),
                      onSpeak: voiceSettings.enabled
                          ? (text) =>
                                unawaited(voiceCtl.speak(text, voiceSettings))
                          : null,
                    ),
                  ),
                ),
              ),
              AnimatedSwitcher(
                duration: AppMotion.medium,
                switchInCurve: AppMotion.emphasizedDecelerate,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SizeTransition(
                    sizeFactor: a,
                    alignment: Alignment.bottomCenter,
                    child: child,
                  ),
                ),
                child: state.busy || state.pending != null || voice.listening
                    ? const SizedBox(width: double.infinity)
                    : QuickCommandBar(
                        key: ValueKey('qc-${commands.length}'),
                        commands: commands,
                        onSelected: (c) => unawaited(_runCommand(c)),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.xs,
                  AppSpacing.md,
                  AppSpacing.sm,
                ),
                child: CoachComposer(
                  controller: _input,
                  focusNode: _focus,
                  enabled: ready && state.pending == null,
                  busy: state.busy,
                  listening: voice.listening,
                  voiceEnabled: voiceSettings.enabled,
                  partial: voice.partial,
                  level: voiceCtl.levels,
                  hint: ready ? 'Ask JARVIS…' : 'AI core offline',
                  onSend: () => unawaited(_send()),
                  onStop: () {
                    Haptics.heavy();
                    unawaited(controller.cancel());
                  },
                  onMicTap: () => unawaited(_onMicTap()),
                  onMicHoldStart: () => unawaited(_onMicHoldStart()),
                  onMicHoldEnd: () => unawaited(voiceCtl.stopListening()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stage layout: header, orb (hero ↔ docked), hero copy, transcript
// ---------------------------------------------------------------------------

const _headerHeight = 116.0;

/// Where the hero orb's box starts and how big the orb is.
({double top, double size}) _heroGeometry(BoxConstraints box) {
  final size = math.min(
    188.0,
    math.max(96.0, (box.maxHeight - _headerHeight) * 0.3),
  );
  return (top: _headerHeight - 26, size: size);
}

class _Stage extends StatelessWidget {
  const _Stage({
    required this.docked,
    required this.header,
    required this.orb,
    required this.hero,
    required this.transcript,
  });

  final bool docked;
  final Widget header;
  final Widget orb;
  final Widget hero;
  final Widget transcript;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final d = reduced ? Duration.zero : const Duration(milliseconds: 520);
    return Stack(
      children: [
        // Transcript, dissolving under the header.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !docked,
            child: AnimatedOpacity(
              opacity: docked ? 1 : 0,
              duration: d,
              child: ShaderMask(
                shaderCallback: (r) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: const [
                    Colors.transparent,
                    Colors.white,
                    Colors.white,
                    Colors.transparent,
                  ],
                  stops: [
                    ((_headerHeight - 24) / r.height).clamp(0.0, 1.0),
                    ((_headerHeight + 20) / r.height).clamp(0.0, 1.0),
                    0.975,
                    1,
                  ],
                ).createShader(r),
                blendMode: BlendMode.dstIn,
                child: transcript,
              ),
            ),
          ),
        ),
        // Greeting and readouts below the big orb.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: docked,
            child: AnimatedOpacity(
              opacity: docked ? 0 : 1,
              duration: d,
              child: hero,
            ),
          ),
        ),
        Positioned(top: 0, left: 0, right: 0, child: header),
        orb,
      ],
    );
  }
}

class _AnimatedCore extends StatelessWidget {
  const _AnimatedCore({
    required this.docked,
    required this.box,
    required this.state,
    required this.level,
    required this.speakProgress,
    required this.wordTick,
    required this.onTap,
    this.onHoldStart,
    this.onHoldEnd,
  });

  final bool docked;
  final BoxConstraints box;
  final OrbState state;
  final Stream<double> level;
  final double speakProgress;
  final int wordTick;
  final VoidCallback onTap;
  final VoidCallback? onHoldStart;
  final VoidCallback? onHoldEnd;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final g = _heroGeometry(box);
    final size = docked ? 46.0 : g.size;
    final outer = size * 1.42;
    final top = docked ? 0.0 : g.top;
    final d = reduced ? Duration.zero : const Duration(milliseconds: 640);
    return AnimatedPositioned(
      duration: d,
      curve: AppMotion.emphasized,
      top: top,
      left: (box.maxWidth - outer) / 2,
      width: outer,
      height: outer,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onTap,
        onLongPressStart: onHoldStart == null ? null : (_) => onHoldStart!(),
        onLongPressEnd: onHoldEnd == null ? null : (_) => onHoldEnd!(),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: size),
          duration: d,
          curve: AppMotion.emphasized,
          builder: (context, s, _) => Center(
            child: JarvisCore(
              state: state,
              size: s,
              level: level,
              speakProgress: speakProgress,
              wordTick: wordTick,
              semanticLabel: switch (state) {
                OrbState.idle => 'JARVIS. Tap to talk',
                OrbState.listening => 'JARVIS is listening. Tap to send',
                OrbState.thinking => 'JARVIS is working',
                OrbState.speaking => 'JARVIS is speaking. Tap to stop',
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.link,
    this.voiceStatus,
    required this.onHistory,
    required this.onNew,
    required this.onMenu,
  });

  final CoachLink link;

  /// Replaces the link line while listening/speaking.
  final String? voiceStatus;
  final VoidCallback onHistory;
  final VoidCallback? onNew;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _headerHeight,
      child: Stack(
        children: [
          Positioned(
            left: 6,
            top: 8,
            child: _HeaderButton(
              icon: Icons.menu_open_rounded,
              label: 'Conversations',
              onTap: onHistory,
            ),
          ),
          Positioned(
            right: 6,
            top: 8,
            child: Row(
              children: [
                _HeaderButton(
                  icon: Icons.add_rounded,
                  label: 'New chat',
                  onTap: onNew,
                ),
                _HeaderButton(
                  icon: Icons.tune_rounded,
                  label: 'Systems',
                  onTap: onMenu,
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 72,
            child: Center(
              child: LinkStatusLine(link: link, voiceText: voiceStatus),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        enabled: onTap != null,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: PressableScale(
          onTap: onTap,
          pressedScale: 0.9,
          child: SizedBox.square(
            dimension: 48,
            child: Icon(
              icon,
              size: 24,
              color: onTap == null
                  ? hud.textMuted.withValues(alpha: 0.5)
                  : hud.text.withValues(alpha: 0.9),
            ),
          ),
        ),
      ),
    );
  }
}

/// "● ONLINE · GEMINI · 1.4 S", the honest link readout.
class LinkStatusLine extends StatelessWidget {
  const LinkStatusLine({super.key, required this.link, this.voiceText});
  final CoachLink link;

  /// Transient voice status shown instead of the link (accent, pulsing).
  final String? voiceText;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final color = switch (link.tone) {
      LinkTone.online => AppColors.success,
      LinkTone.fallback => AppColors.warning,
      LinkTone.degraded => AppColors.warning,
      LinkTone.offline => AppColors.danger,
      LinkTone.linking => hud.accent,
    };
    final latency = link.latency == null || link.latency!.inMilliseconds < 100
        ? ''
        : ' · ${(link.latency!.inMilliseconds / 1000).toStringAsFixed(1)} S';
    final text =
        voiceText?.toUpperCase() ??
        '${link.label} · ${link.detail}'.toUpperCase() + latency;
    return Semantics(
      label: 'AI link: ${link.label}, ${link.detail}',
      excludeSemantics: true,
      child: AnimatedSwitcher(
        duration: AppMotion.medium,
        child: Row(
          key: ValueKey(text),
          mainAxisSize: MainAxisSize.min,
          children: [
            _PulseDot(
              color: voiceText != null ? hud.accent : color,
              pulse: voiceText != null || link.tone == LinkTone.linking,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: hud.mono(
                  size: 11,
                  color: hud.text.withValues(alpha: 0.85),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.color, this.pulse = false});
  final Color color;
  final bool pulse;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
    value: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_PulseDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.pulse && !AppMotion.reduced(context)) {
      if (!_c.isAnimating) unawaited(_c.repeat(reverse: true));
    } else {
      _c
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final a = 0.45 + 0.55 * _c.value;
        return Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color.withValues(alpha: a),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.7 * a),
                blurRadius: 8,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Hero (empty session)
// ---------------------------------------------------------------------------

class _Hero extends StatelessWidget {
  const _Hero({
    required this.now,
    required this.telemetry,
    required this.link,
    required this.backendState,
    required this.listening,
    required this.partial,
  });

  final DateTime now;
  final CoachTelemetry? telemetry;
  final CoachLink link;
  final AiBackendState backendState;
  final bool listening;
  final String partial;

  static String greeting(DateTime now, String? name) {
    final h = now.hour;
    final part = h < 5
        ? 'Burning the midnight oil'
        : h < 12
        ? 'Good morning'
        : h < 17
        ? 'Good afternoon'
        : 'Good evening';
    final n = (name ?? '').trim();
    return n.isEmpty ? '$part.' : '$part, $n.';
  }

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    final ready = backendState == AiBackendState.ready;
    return LayoutBuilder(
      builder: (context, box) {
        final g = _heroGeometry(box);
        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            g.top + g.size * 1.42 + AppSpacing.xs,
            AppSpacing.gutter,
            AppSpacing.md,
          ),
          child: Column(
            children: [
              Text('J · A · R · V · I · S', style: hud.label(size: 12)),
              const SizedBox(height: AppSpacing.sm),
              Text(
                listening ? 'Listening…' : greeting(now, telemetry?.name),
                textAlign: TextAlign.center,
                style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                listening
                    ? (partial.isEmpty
                          ? "Go ahead, I'm listening."
                          : '"$partial"')
                    : ready
                    ? switch (link.tone) {
                        LinkTone.fallback =>
                          'Running on the backup core. Still at your service.',
                        LinkTone.degraded =>
                          'The AI core is degraded. Local briefings still '
                              'work.',
                        _ => 'All systems nominal. What do you need?',
                      }
                    : 'Local systems online. The AI core is not connected.',
                textAlign: TextAlign.center,
                style: t.bodyLarge?.copyWith(color: hud.textMuted),
              ),
              if (!ready && !listening) ...[
                const SizedBox(height: AppSpacing.lg),
                _OfflineCard(backendState: backendState),
              ] else if (telemetry != null && !listening) ...[
                const SizedBox(height: AppSpacing.lg),
                _Readouts(telemetry: telemetry!),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _OfflineCard extends StatelessWidget {
  const _OfflineCard({required this.backendState});
  final AiBackendState backendState;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = HudTheme.of(context);
    final unconfigured = backendState == AiBackendState.unconfigured;
    return GlassPanel(
      accent: AppColors.warning,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          const GlowIcon(
            Icons.cloud_off_rounded,
            color: AppColors.warning,
            size: 20,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  unconfigured ? 'AI core not configured' : 'Not signed in',
                  style: t.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  unconfigured
                      ? 'No answers are generated until it is connected. '
                            '“Brief me” works offline.'
                      : 'Sign in to the AI core to start.',
                  style: t.bodySmall?.copyWith(color: hud.textMuted),
                ),
              ],
            ),
          ),
          HudButton.ghost(
            label: 'Set up',
            compact: true,
            onPressed: () => context.push(AppPaths.aiSettings),
          ),
        ],
      ),
    );
  }
}

/// Up to three live readouts under the greeting (only what is known).
class _Readouts extends StatelessWidget {
  const _Readouts({required this.telemetry});
  final CoachTelemetry telemetry;

  static String _k(int v) =>
      v >= 1000 && v % 1000 == 0 ? '${v ~/ 1000}K' : Fmt.integer(v);

  @override
  Widget build(BuildContext context) {
    final items = <(String, String, Color)>[
      if (telemetry.steps != null && telemetry.stepGoal != null)
        (
          'STEPS',
          '${Fmt.integer(telemetry.steps!)} / ${_k(telemetry.stepGoal!)}',
          AppColors.steps,
        ),
      if (telemetry.proteinLeft != null)
        (
          'PROTEIN LEFT',
          telemetry.proteinLeft! <= 0
              ? 'DONE'
              : '${telemetry.proteinLeft!.round()} g',
          AppColors.protein,
        ),
      if (telemetry.waterLeftMl != null)
        (
          'WATER LEFT',
          telemetry.waterLeftMl! <= 0
              ? 'DONE'
              : '${(telemetry.waterLeftMl! / 1000).toStringAsFixed(1)} L',
          AppColors.water,
        ),
      if (telemetry.daysToCompetition != null &&
          telemetry.daysToCompetition! >= 0)
        ('MEET IN', '${telemetry.daysToCompetition} d', AppColors.competition),
      if (telemetry.pendingDrafts > 0)
        ('REPLIES', '${telemetry.pendingDrafts} waiting', AppColors.gold),
    ].take(3).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Entrance(
              delay: Duration(milliseconds: 200 + 70 * i),
              child: _Readout(
                label: items[i].$1,
                value: items[i].$2,
                color: items[i].$3,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _Readout extends StatelessWidget {
  const _Readout({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    return GlassPanel(
      accent: color,
      radius: AppRadii.md,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: Column(
        children: [
          Text(
            label,
            style: hud.label(size: 10.5, color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: AnimatedTicker(value, style: hud.number(size: 20)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Transcript
// ---------------------------------------------------------------------------

class _Transcript extends ConsumerWidget {
  const _Transcript({
    required this.state,
    required this.animateFrom,
    required this.link,
    required this.scroll,
    required this.onRetry,
    required this.onFastRetry,
    required this.onSettings,
    required this.onSpeak,
  });

  final CoachState state;
  final int animateFrom;
  final CoachLink link;
  final ScrollController scroll;
  final VoidCallback onRetry;
  final VoidCallback onFastRetry;
  final VoidCallback onSettings;
  final void Function(String text)? onSpeak;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = <Widget>[];
    final entries = state.entries;
    var i = 0;
    while (i < entries.length) {
      final e = entries[i];
      final animate = i >= animateFrom;
      switch (e) {
        case UserTextEntry():
          items.add(UserLine(e.text, animate: animate));
          i++;
        case AssistantTextEntry():
          items.add(
            JarvisReply(
              key: ValueKey('reply-$i'),
              text: e.text,
              sources: e.sources,
              model: e.model,
              animate: animate,
              onSpeak: onSpeak == null ? null : () => onSpeak!(e.text),
            ),
          );
          i++;
        case BriefingEntry():
          items.add(
            _BriefingBlock(
              key: ValueKey('brief-$i-${e.polished}'),
              entry: e,
              animate: animate,
              onSpeak: onSpeak == null ? null : () => onSpeak!(e.text),
            ),
          );
          i++;
        case ToolChipEntry():
          final group = <ToolChipEntry>[];
          while (i < entries.length && entries[i] is ToolChipEntry) {
            group.add(entries[i] as ToolChipEntry);
            i++;
          }
          items.add(SubsystemTrace(entries: group));
      }
    }
    if (state.busy) {
      final provider = link.detail == 'Unverified' || link.detail == 'AI core'
          ? 'AI core'
          : link.detail;
      items.add(
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.sm, left: 16),
          child: ConsultingLine(
            key: ValueKey('consult-${state.phase.name}'),
            since: state.phaseSince,
            provider: provider,
            label: switch (state.phase) {
              CoachPhase.tools => 'Cross-referencing your data',
              CoachPhase.briefing =>
                state.statusText == 'Polishing…'
                    ? 'Refining briefing via $provider'
                    : 'Compiling briefing from local data',
              _ => null,
            },
          ),
        ),
      );
    }
    if (state.pending != null) {
      final controller = ref.read(coachControllerProvider.notifier);
      items.add(
        PendingActionCard(
          pending: state.pending!,
          onApprove: (edited) => controller.approve(editedArgs: edited),
          onReject: controller.reject,
        ),
      );
    }
    if (state.error != null) {
      final e = state.error!;
      final fast =
          e.retryable &&
          const {
            'timeout',
            'upstream_error',
            'providers_unavailable',
            'internal',
          }.contains(e.code);
      items.add(
        LinkFaultCard(
          error: e,
          onRetry: state.canRetry ? onRetry : null,
          onFastRetry: fast ? onFastRetry : null,
          onSettings:
              const {
                'awaiting_credentials',
                'unauthorized',
                'budget_exceeded',
              }.contains(e.code)
              ? onSettings
              : null,
        ),
      );
    }
    if (state.notice != null) {
      items.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          child: Center(
            child: Text(
              '— ${state.notice!} —',
              textAlign: TextAlign.center,
              style: HudTheme.of(context).mono(size: 11),
            ),
          ),
        ),
      );
    }
    return ListView(
      controller: scroll,
      reverse: true,
      // SliverPadding is visual: top clears the header even when reversed.
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        _headerHeight + AppSpacing.sm,
        AppSpacing.gutter,
        AppSpacing.md,
      ),
      children: items.reversed.toList(),
    );
  }
}

class _BriefingBlock extends StatelessWidget {
  const _BriefingBlock({
    super.key,
    required this.entry,
    required this.animate,
    this.onSpeak,
  });

  final BriefingEntry entry;
  final bool animate;
  final VoidCallback? onSpeak;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final morning = entry.mode == 'morning';
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: HudFrame(
        cornerLength: 14,
        inset: -2,
        padding: const EdgeInsets.fromLTRB(10, 2, 10, 12),
        child: JarvisReply(
          text: entry.text,
          animate: animate,
          eyebrow: morning ? 'MORNING BRIEFING' : 'EVENING REVIEW',
          onSpeak: onSpeak,
          footer: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                const HudChip(
                  label: 'Local data',
                  dot: true,
                  color: AppColors.success,
                ),
                if (entry.polished)
                  HudChip(
                    label: 'AI-polished',
                    icon: Icons.auto_awesome_rounded,
                    color: hud.accent,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MicExplainer extends StatelessWidget {
  const _MicExplainer();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = HudTheme.of(context);
    Widget point(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GlowIcon(icon, size: 18, framed: true),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: Text(text, style: t.bodyMedium)),
        ],
      ),
    );
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Voice needs the microphone. Android will ask next.',
            style: t.bodyLarge?.copyWith(color: hud.textMuted),
          ),
          const SizedBox(height: AppSpacing.lg),
          point(
            Icons.touch_app_outlined,
            'The mic is live only while you hold the button, or from a tap '
            'until you stop talking.',
          ),
          point(
            Icons.record_voice_over_outlined,
            "Your phone's speech service turns speech into text. Only that "
            'text goes to the coach, exactly like typing.',
          ),
          point(
            Icons.no_sim_outlined,
            'No audio is recorded or stored. Turn voice off any time in '
            'Systems › Voice.',
          ),
          const SizedBox(height: AppSpacing.sm),
          HudButton(
            label: 'Continue',
            icon: Icons.mic_rounded,
            expand: true,
            onPressed: () => Navigator.pop(context, true),
          ),
          const SizedBox(height: AppSpacing.sm),
          HudButton.ghost(
            label: 'Not now',
            expand: true,
            onPressed: () => Navigator.pop(context, false),
          ),
        ],
      ),
    );
  }
}
