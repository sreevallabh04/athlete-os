import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'speech_ports.dart';
import 'voice_settings.dart';

/// Turns a markdown-lite answer into something worth hearing: no markup,
/// no tables, no long lists — the opening sentence(s), up to [maxChars].
/// Pure; unit-tested.
String speakableSummary(String text, {int maxChars = 260}) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      // Tables, code fences and headings are for eyes only.
      .where((l) => !l.startsWith('|') && !l.startsWith('```'))
      .toList();
  if (lines.isEmpty) return '';
  String clean(String s) => s
      .replaceAll(RegExp(r'^#{1,4}\s+'), '')
      .replaceAll(RegExp(r'^\s*([-*•]|\d{1,2}[.)])\s+'), '')
      .replaceAll(RegExp(r'\*\*|__|`'), '')
      .replaceAll('✓', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final out = StringBuffer();
  var bullets = 0;
  for (final raw in lines) {
    final isBullet = RegExp(r'^([-*•]|\d{1,2}[.)])\s+').hasMatch(raw);
    if (isBullet) {
      bullets++;
      if (bullets > 3) break;
    }
    var s = clean(raw);
    if (s.isEmpty) continue;
    if (!RegExp(r'[.!?…:]$').hasMatch(s)) s = '$s.';
    if (out.length + s.length + 1 > maxChars) {
      if (out.isEmpty) {
        // First sentence alone is too long: cut at a sentence/word break.
        final cut = s.substring(0, maxChars);
        final dot = cut.lastIndexOf(RegExp(r'[.!?]\s'));
        out.write(
          dot > 60
              ? cut.substring(0, dot + 1)
              : '${cut.substring(0, cut.lastIndexOf(' '))}…',
        );
      }
      break;
    }
    if (out.isNotEmpty) out.write(' ');
    out.write(s);
  }
  return out.toString();
}

enum VoicePhase {
  idle,

  /// Initialising / waiting for the permission dialog.
  starting,
  listening,
  speaking,
}

class VoiceState {
  const VoiceState({
    this.phase = VoicePhase.idle,
    this.partial = '',
    this.issue,
    this.speakProgress = 0,
    this.wordTick = 0,
    this.message,
  });

  final VoicePhase phase;

  /// Live transcript while listening.
  final String partial;
  final RecognizerIssue? issue;

  /// 0..1 progress through the current utterance (TTS word boundaries).
  final double speakProgress;

  /// Increments on every spoken word (drives orb pulses).
  final int wordTick;

  /// Short user-facing status ("Didn't catch that").
  final String? message;

  bool get listening => phase == VoicePhase.listening;
  bool get speaking => phase == VoicePhase.speaking;

  VoiceState copyWith({
    VoicePhase? phase,
    String? partial,
    RecognizerIssue? Function()? issue,
    double? speakProgress,
    int? wordTick,
    String? Function()? message,
  }) => VoiceState(
    phase: phase ?? this.phase,
    partial: partial ?? this.partial,
    issue: issue != null ? issue() : this.issue,
    speakProgress: speakProgress ?? this.speakProgress,
    wordTick: wordTick ?? this.wordTick,
    message: message != null ? message() : this.message,
  );
}

/// Push-to-talk and spoken replies. Owns the recogniser/TTS lifecycles; the
/// Coach screen decides what to do with transcripts.
class VoiceController extends Notifier<VoiceState> {
  final _levels = StreamController<double>.broadcast();
  bool _initialised = false;
  void Function(String text)? _onFinal;
  String _last = '';
  bool _delivered = false;
  int _speakGen = 0;

  /// Normalised microphone level (0..1) while listening.
  Stream<double> get levels => _levels.stream;

  @override
  VoiceState build() {
    ref.onDispose(() {
      unawaited(_levels.close());
      _speakGen++;
    });
    return const VoiceState();
  }

  SpeechRecognizerPort get _stt => ref.read(speechRecognizerProvider);
  SpeechSynthPort get _tts => ref.read(speechSynthProvider);

  /// True when RECORD_AUDIO is already granted (no explanation needed).
  Future<bool> hasPermission() => _stt.hasPermission();

  /// Starts listening; [onFinal] receives the final transcript once (only
  /// if something was recognised). Stops any speech first.
  Future<bool> startListening({
    required void Function(String text) onFinal,
    bool preferOffline = false,
  }) async {
    if (state.phase == VoicePhase.listening ||
        state.phase == VoicePhase.starting) {
      return true;
    }
    await stopSpeaking();
    _onFinal = onFinal;
    _last = '';
    _delivered = false;
    state = state.copyWith(
      phase: VoicePhase.starting,
      partial: '',
      message: () => null,
    );
    if (!_initialised) {
      final issue = await _stt.initialize(
        onStatus: _onStatus,
        onError: (e, permanent) {
          if (!ref.mounted) return;
          final noMatch =
              e.contains('no_match') || e.contains('speech_timeout');
          state = state.copyWith(
            phase: VoicePhase.idle,
            message: () =>
                noMatch ? "I didn't catch that." : 'Voice input stopped ($e).',
          );
          if (!_levels.isClosed) _levels.add(0);
        },
      );
      if (!ref.mounted) return false;
      if (issue != null) {
        state = state.copyWith(phase: VoicePhase.idle, issue: () => issue);
        return false;
      }
      _initialised = true;
    }
    state = state.copyWith(issue: () => null);
    try {
      await _stt.listen(
        preferOffline: preferOffline,
        onLevel: (l) {
          if (!_levels.isClosed) _levels.add(l);
        },
        onResult: (words, isFinal) {
          if (!ref.mounted) return;
          _last = words;
          state = state.copyWith(partial: words);
          if (isFinal) _deliver();
        },
      );
      if (!ref.mounted) return false;
      // A fast final result may already have been delivered.
      if (!_delivered && state.phase == VoicePhase.starting) {
        state = state.copyWith(phase: VoicePhase.listening);
      }
      return true;
    } catch (e) {
      if (!ref.mounted) return false;
      state = state.copyWith(
        phase: VoicePhase.idle,
        issue: () => RecognizerIssue.unavailable,
      );
      return false;
    }
  }

  void _onStatus(String status) {
    if (!ref.mounted) return;
    if (status == 'done' || status == 'notListening') {
      if (state.phase == VoicePhase.listening ||
          state.phase == VoicePhase.starting) {
        state = state.copyWith(phase: VoicePhase.idle);
        if (!_levels.isClosed) _levels.add(0);
      }
      if (status == 'done') _deliver();
    }
  }

  void _deliver() {
    if (_delivered) return;
    final text = _last.trim();
    if (text.isEmpty) return;
    _delivered = true;
    state = state.copyWith(phase: VoicePhase.idle, partial: '');
    final cb = _onFinal;
    _onFinal = null;
    cb?.call(text);
  }

  /// Stops listening and sends what was heard (push-to-talk release).
  Future<void> stopListening() async {
    if (state.phase != VoicePhase.listening &&
        state.phase != VoicePhase.starting) {
      return;
    }
    await _stt.stop();
    if (!ref.mounted) return;
    state = state.copyWith(phase: VoicePhase.idle);
    if (!_levels.isClosed) _levels.add(0);
    // Some engines never send "done" after stop(); deliver the partial.
    _deliver();
  }

  /// Stops listening and discards the transcript.
  Future<void> cancelListening() async {
    _onFinal = null;
    _delivered = true;
    await _stt.cancel();
    if (!ref.mounted) return;
    state = state.copyWith(phase: VoicePhase.idle, partial: '');
    if (!_levels.isClosed) _levels.add(0);
  }

  /// Speaks a concise version of [text] (see [speakableSummary]).
  Future<void> speak(String text, VoiceSettings settings) async {
    final summary = speakableSummary(text);
    if (summary.isEmpty || !settings.enabled) return;
    final gen = ++_speakGen;
    try {
      if (state.listening) await cancelListening();
      final voices = settings.voiceName == null ? await _tts.voices() : null;
      final voice = settings.voiceName != null
          ? TtsVoice(settings.voiceName!, settings.voiceLocale ?? 'en-GB')
          : pickDefaultVoice(voices ?? const []);
      await _tts.configure(
        voice: voice,
        rate: settings.rate,
        pitch: settings.pitch,
      );
      if (gen != _speakGen || !ref.mounted) return;
      state = state.copyWith(phase: VoicePhase.speaking, speakProgress: 0);
      await _tts.speak(
        summary,
        onProgress: (start, end) {
          if (gen != _speakGen || !ref.mounted) return;
          state = state.copyWith(
            speakProgress: (end / summary.length).clamp(0.0, 1.0),
            wordTick: state.wordTick + 1,
          );
        },
      );
    } catch (_) {
      // A TTS engine failure must never crash the coach (callers fire and
      // forget); the answer stays on screen.
    }
    if (gen != _speakGen || !ref.mounted) return;
    state = state.copyWith(phase: VoicePhase.idle, speakProgress: 1);
  }

  Future<void> stopSpeaking() async {
    if (state.phase != VoicePhase.speaking) return;
    _speakGen++;
    await _tts.stop();
    if (!ref.mounted) return;
    state = state.copyWith(phase: VoicePhase.idle);
  }

  void clearMessage() =>
      state = state.copyWith(message: () => null, issue: () => null);
}

final voiceControllerProvider = NotifierProvider<VoiceController, VoiceState>(
  VoiceController.new,
);
