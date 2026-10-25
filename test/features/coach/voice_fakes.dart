import 'dart:async';

import 'package:athlete_os/features/coach/voice/speech_ports.dart';

/// Scriptable recogniser: tests drive partial/final results and levels.
class FakeRecognizer implements SpeechRecognizerPort {
  FakeRecognizer({
    this.permission = true,
    this.issue,
    this.partial = '',
    this.level = 0.6,
  });

  bool permission;
  RecognizerIssue? issue;

  /// Emitted (as a partial result) as soon as listening starts.
  String partial;
  double level;

  int initCalls = 0;
  int listenCalls = 0;
  int stopCalls = 0;
  void Function(String, bool)? _onResult;
  void Function(String)? _onStatus;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<RecognizerIssue?> initialize({
    required void Function(String status) onStatus,
    required void Function(String error, bool permanent) onError,
  }) async {
    initCalls++;
    _onStatus = onStatus;
    if (issue == null) permission = true;
    return issue;
  }

  @override
  Future<void> listen({
    required void Function(String words, bool isFinal) onResult,
    required void Function(double level) onLevel,
    bool preferOffline = false,
    Duration listenFor = const Duration(seconds: 45),
    Duration pauseFor = const Duration(seconds: 3),
  }) async {
    listenCalls++;
    _onResult = onResult;
    _onStatus?.call('listening');
    onLevel(level);
    if (partial.isNotEmpty) onResult(partial, false);
  }

  /// Simulates the engine delivering a final transcript.
  void finish(String words) {
    _onResult?.call(words, true);
    _onStatus?.call('done');
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _onStatus?.call('notListening');
  }

  @override
  Future<void> cancel() async => _onStatus?.call('notListening');
}

/// Records what would be spoken; completes immediately (or on demand).
class FakeSynth implements SpeechSynthPort {
  FakeSynth({this.hold = false});

  /// Keep "speaking" until [release] is called.
  bool hold;
  final spoken = <String>[];
  TtsVoice? configuredVoice;
  double? rate;
  Completer<void>? _pending;

  @override
  Future<List<TtsVoice>> voices() async => const [
    TtsVoice('en-gb-x-rjs-local', 'en-GB'),
    TtsVoice('en-gb-x-gba-local', 'en-GB'),
    TtsVoice('en-us-x-iol-local', 'en-US'),
    TtsVoice('en-in-x-ene-network', 'en-IN', network: true),
  ];

  @override
  Future<void> configure({
    TtsVoice? voice,
    double rate = 0.46,
    double pitch = 0.92,
  }) async {
    configuredVoice = voice;
    this.rate = rate;
  }

  @override
  Future<void> speak(
    String text, {
    void Function(int start, int end)? onProgress,
  }) async {
    spoken.add(text);
    onProgress?.call(0, text.length ~/ 3);
    if (hold) {
      _pending = Completer<void>();
      await _pending!.future;
    }
    onProgress?.call(0, text.length);
  }

  void release() => _pending?.complete();

  @override
  Future<void> stop() async {
    if (!(_pending?.isCompleted ?? true)) _pending!.complete();
  }
}
