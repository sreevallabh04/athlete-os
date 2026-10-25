import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Why speech input is not available.
enum RecognizerIssue {
  /// The user denied RECORD_AUDIO (or it was revoked).
  permissionDenied,

  /// No speech recognition service on the device (or it failed to start).
  unavailable,
}

/// Speech-to-text, behind an interface so the coach can be tested without
/// platform channels. See docs/VOICE.md.
abstract interface class SpeechRecognizerPort {
  /// True if RECORD_AUDIO is already granted (never prompts).
  Future<bool> hasPermission();

  /// Initialises the recogniser; on Android this shows the system
  /// microphone permission dialog the first time. Returns null on success.
  Future<RecognizerIssue?> initialize({
    required void Function(String status) onStatus,
    required void Function(String error, bool permanent) onError,
  });

  /// Starts listening. [onResult] gets partial and final transcripts;
  /// [onLevel] gets a normalised 0..1 microphone level.
  Future<void> listen({
    required void Function(String words, bool isFinal) onResult,
    required void Function(double level) onLevel,
    bool preferOffline = false,
    Duration listenFor = const Duration(seconds: 45),
    Duration pauseFor = const Duration(seconds: 3),
  });

  /// Stops listening and delivers the final result.
  Future<void> stop();

  /// Stops listening and discards the result.
  Future<void> cancel();
}

/// One TTS voice as reported by the engine.
class TtsVoice {
  const TtsVoice(this.name, this.locale, {this.network = false});
  final String name;
  final String locale;
  final bool network;

  String get label {
    final loc = locale.replaceAll('_', '-');
    final region = switch (loc.toLowerCase()) {
      'en-gb' => 'British',
      'en-us' => 'American',
      'en-au' => 'Australian',
      'en-in' => 'Indian',
      'en-ie' => 'Irish',
      _ => loc,
    };
    // Google voice names look like "en-gb-x-rjs-local": keep the id.
    final m = RegExp(r'-x-([a-z0-9]+)-').firstMatch(name);
    final id = m?.group(1)?.toUpperCase() ?? name;
    return '$region · $id${network ? ' · cloud' : ''}';
  }

  @override
  bool operator ==(Object other) =>
      other is TtsVoice && other.name == name && other.locale == locale;

  @override
  int get hashCode => Object.hash(name, locale);
}

/// Text-to-speech, behind an interface (see [SpeechRecognizerPort]).
abstract interface class SpeechSynthPort {
  Future<List<TtsVoice>> voices();

  Future<void> configure({TtsVoice? voice, double rate, double pitch});

  /// Speaks [text]. [onProgress] reports the character range being spoken
  /// (word boundaries); completes when speech ends or is stopped.
  Future<void> speak(
    String text, {
    void Function(int start, int end)? onProgress,
  });

  Future<void> stop();
}

/// Picks a calm British English voice when one exists: en-GB, on-device,
/// preferring Google's male voices (`rjs`, `gbd`), then any en-GB, then any
/// English voice.
TtsVoice? pickDefaultVoice(List<TtsVoice> voices) {
  String norm(String l) => l.replaceAll('_', '-').toLowerCase();
  final gb = voices.where((v) => norm(v.locale) == 'en-gb').toList()
    ..sort((a, b) {
      int score(TtsVoice v) =>
          (v.network ? 10 : 0) +
          (v.name.contains('rjs')
              ? 0
              : v.name.contains('gbd')
              ? 1
              : 3);
      return score(a).compareTo(score(b));
    });
  if (gb.isNotEmpty) return gb.first;
  final en = voices.where((v) => norm(v.locale).startsWith('en')).toList()
    ..sort((a, b) => (a.network ? 1 : 0).compareTo(b.network ? 1 : 0));
  return en.firstOrNull;
}

// ---------------------------------------------------------------------------
// Plugin implementations
// ---------------------------------------------------------------------------

/// Android/iOS speech recognition via `speech_to_text`.
class PluginSpeechRecognizer implements SpeechRecognizerPort {
  final SpeechToText _stt = SpeechToText();
  void Function(String, bool)? _onResult;
  void Function(double)? _onLevel;

  @override
  Future<bool> hasPermission() async {
    try {
      return await _stt.hasPermission;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<RecognizerIssue?> initialize({
    required void Function(String status) onStatus,
    required void Function(String error, bool permanent) onError,
  }) async {
    try {
      final ok = await _stt.initialize(
        onStatus: onStatus,
        onError: (SpeechRecognitionError e) => onError(e.errorMsg, e.permanent),
      );
      if (ok) return null;
      return await hasPermission()
          ? RecognizerIssue.unavailable
          : RecognizerIssue.permissionDenied;
    } catch (e) {
      debugPrint('speech init failed: $e');
      return RecognizerIssue.unavailable;
    }
  }

  @override
  Future<void> listen({
    required void Function(String words, bool isFinal) onResult,
    required void Function(double level) onLevel,
    bool preferOffline = false,
    Duration listenFor = const Duration(seconds: 45),
    Duration pauseFor = const Duration(seconds: 3),
  }) async {
    _onResult = onResult;
    _onLevel = onLevel;
    await _stt.listen(
      onResult: (SpeechRecognitionResult r) =>
          _onResult?.call(r.recognizedWords, r.finalResult),
      // Android reports RMS dB, roughly -2..10. Normalise to 0..1.
      onSoundLevelChange: (db) =>
          _onLevel?.call(((db + 2) / 12).clamp(0.0, 1.0)),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        onDevice: preferOffline,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
        listenFor: listenFor,
        pauseFor: pauseFor,
      ),
    );
  }

  @override
  Future<void> stop() async {
    try {
      await _stt.stop();
    } catch (_) {}
  }

  @override
  Future<void> cancel() async {
    try {
      await _stt.cancel();
    } catch (_) {}
  }
}

/// Android TTS via `flutter_tts`.
class PluginSpeechSynth implements SpeechSynthPort {
  PluginSpeechSynth() {
    _tts.setStartHandler(() {});
    _tts.setCompletionHandler(_complete);
    _tts.setCancelHandler(_complete);
    _tts.setErrorHandler((_) => _complete());
    _tts.setProgressHandler((text, start, end, word) {
      _progress?.call(start, end);
    });
  }

  final FlutterTts _tts = FlutterTts();
  Completer<void>? _done;
  void Function(int, int)? _progress;

  void _complete() {
    final d = _done;
    _done = null;
    if (d != null && !d.isCompleted) d.complete();
  }

  @override
  Future<List<TtsVoice>> voices() async {
    try {
      final raw = await _tts.getVoices;
      if (raw is! List) return const [];
      return [
        for (final v in raw)
          if (v is Map && v['name'] != null && v['locale'] != null)
            TtsVoice(
              '${v['name']}',
              '${v['locale']}',
              network:
                  '${v['network_required']}' == '1' ||
                  '${v['network_required']}' == 'true',
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> configure({
    TtsVoice? voice,
    double rate = 0.46,
    double pitch = 0.92,
  }) async {
    try {
      if (voice != null) {
        await _tts.setVoice({'name': voice.name, 'locale': voice.locale});
      } else {
        await _tts.setLanguage('en-GB');
      }
      await _tts.setSpeechRate(rate);
      await _tts.setPitch(pitch);
      await _tts.awaitSpeakCompletion(false);
    } catch (e) {
      debugPrint('tts configure failed: $e');
    }
  }

  @override
  Future<void> speak(
    String text, {
    void Function(int start, int end)? onProgress,
  }) async {
    _complete();
    _progress = onProgress;
    final done = _done = Completer<void>();
    try {
      final r = await _tts.speak(text);
      if (r != 1) _complete();
    } catch (_) {
      _complete();
    }
    // Safety net: never hang if the engine drops the completion callback.
    await done.future.timeout(
      Duration(seconds: 8 + text.length ~/ 8),
      onTimeout: () {},
    );
    _progress = null;
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
    _complete();
  }
}

final speechRecognizerProvider = Provider<SpeechRecognizerPort>(
  (ref) => PluginSpeechRecognizer(),
);

final speechSynthProvider = Provider<SpeechSynthPort>(
  (ref) => PluginSpeechSynth(),
);
