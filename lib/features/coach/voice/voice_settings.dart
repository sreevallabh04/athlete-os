import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/settings_repository.dart';

/// When JARVIS reads answers aloud.
enum AutoSpeak {
  off('Off'),

  /// Only answers to questions asked by voice (default).
  voice('When I speak'),
  always('Always');

  const AutoSpeak(this.label);
  final String label;

  static AutoSpeak fromKey(Object? k) =>
      values.firstWhere((v) => v.name == k, orElse: () => AutoSpeak.voice);
}

/// Voice preferences, stored as one JSON object under [VoiceSettings.key].
class VoiceSettings {
  const VoiceSettings({
    this.enabled = true,
    this.autoSpeak = AutoSpeak.voice,
    this.voiceName,
    this.voiceLocale,
    this.rate = 0.46,
    this.pitch = 0.92,
    this.wakeOnOpen = false,
    this.preferOffline = false,
    this.micExplained = false,
  });

  static const key = 'ai.voice';

  /// Voice input + spoken replies at all.
  final bool enabled;
  final AutoSpeak autoSpeak;

  /// TTS voice (null = best British English voice available).
  final String? voiceName;
  final String? voiceLocale;

  /// flutter_tts Android scale: 0.5 = normal speed.
  final double rate;

  /// 1.0 = normal pitch.
  final double pitch;

  /// Start listening as soon as the Coach opens (off by default).
  final bool wakeOnOpen;

  /// Ask the recogniser to stay on-device (fails if no offline model).
  final bool preferOffline;

  /// The microphone explanation sheet was shown and accepted once.
  final bool micExplained;

  VoiceSettings copyWith({
    bool? enabled,
    AutoSpeak? autoSpeak,
    String? Function()? voiceName,
    String? Function()? voiceLocale,
    double? rate,
    double? pitch,
    bool? wakeOnOpen,
    bool? preferOffline,
    bool? micExplained,
  }) => VoiceSettings(
    enabled: enabled ?? this.enabled,
    autoSpeak: autoSpeak ?? this.autoSpeak,
    voiceName: voiceName != null ? voiceName() : this.voiceName,
    voiceLocale: voiceLocale != null ? voiceLocale() : this.voiceLocale,
    rate: rate ?? this.rate,
    pitch: pitch ?? this.pitch,
    wakeOnOpen: wakeOnOpen ?? this.wakeOnOpen,
    preferOffline: preferOffline ?? this.preferOffline,
    micExplained: micExplained ?? this.micExplained,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'auto_speak': autoSpeak.name,
    'voice_name': voiceName,
    'voice_locale': voiceLocale,
    'rate': rate,
    'pitch': pitch,
    'wake_on_open': wakeOnOpen,
    'prefer_offline': preferOffline,
    'mic_explained': micExplained,
  };

  factory VoiceSettings.fromJson(Map<String, Object?>? j) {
    if (j == null) return const VoiceSettings();
    double dbl(Object? v, double d, double lo, double hi) =>
        v is num ? v.toDouble().clamp(lo, hi) : d;
    return VoiceSettings(
      enabled: j['enabled'] as bool? ?? true,
      autoSpeak: AutoSpeak.fromKey(j['auto_speak']),
      voiceName: j['voice_name'] as String?,
      voiceLocale: j['voice_locale'] as String?,
      rate: dbl(j['rate'], 0.46, 0.2, 0.9),
      pitch: dbl(j['pitch'], 0.92, 0.6, 1.4),
      wakeOnOpen: j['wake_on_open'] as bool? ?? false,
      preferOffline: j['prefer_offline'] as bool? ?? false,
      micExplained: j['mic_explained'] as bool? ?? false,
    );
  }
}

class VoiceSettingsRepository {
  VoiceSettingsRepository(this._settings);
  final SettingsRepository _settings;

  Future<VoiceSettings> load() async => VoiceSettings.fromJson(
    (await _settings.get<Map<String, dynamic>>(VoiceSettings.key))
        ?.cast<String, Object?>(),
  );

  Stream<VoiceSettings> watch() => _settings
      .watch<Map<String, dynamic>>(VoiceSettings.key)
      .map((m) => VoiceSettings.fromJson(m?.cast<String, Object?>()));

  Future<void> save(VoiceSettings s) =>
      _settings.set(VoiceSettings.key, s.toJson());

  Future<void> update(VoiceSettings Function(VoiceSettings) f) async =>
      save(f(await load()));
}

final voiceSettingsRepositoryProvider = Provider<VoiceSettingsRepository>(
  (ref) => VoiceSettingsRepository(ref.watch(settingsRepositoryProvider)),
);

final voiceSettingsProvider = StreamProvider<VoiceSettings>(
  (ref) => ref.watch(voiceSettingsRepositoryProvider).watch(),
);
