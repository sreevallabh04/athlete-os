import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/coach/voice/speech_ports.dart';
import '../../features/nutrition/application/ai_food_log.dart';

/// Adapts the coach's on-device speech recogniser ([SpeechRecognizerPort])
/// to the nutrition composer's [FoodDictation] contract. Audio never leaves
/// the device through this path; only the resulting text is used.
class SpeechFoodDictation implements FoodDictation {
  SpeechFoodDictation(this._stt);
  final SpeechRecognizerPort _stt;

  @override
  Future<String?> start({
    required void Function(String words, bool isFinal) onWords,
    void Function(double level)? onLevel,
  }) async {
    final issue = await _stt.initialize(onStatus: (_) {}, onError: (_, _) {});
    switch (issue) {
      case RecognizerIssue.permissionDenied:
        return 'Microphone permission is off. Allow it in system settings '
            'to dictate.';
      case RecognizerIssue.unavailable:
        return 'Speech recognition isn\'t available on this device.';
      case null:
        break;
    }
    try {
      await _stt.listen(
        onResult: onWords,
        onLevel: onLevel ?? (_) {},
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 4),
      );
      return null;
    } catch (_) {
      return 'Couldn\'t start the microphone. Try again.';
    }
  }

  @override
  Future<void> stop() => _stt.stop();

  @override
  Future<void> cancel() => _stt.cancel();
}

final speechFoodDictationProvider = Provider<FoodDictation?>(
  (ref) => SpeechFoodDictation(ref.watch(speechRecognizerProvider)),
);
