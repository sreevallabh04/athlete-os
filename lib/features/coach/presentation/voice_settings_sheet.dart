import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../voice/speech_ports.dart';
import '../voice/voice_controller.dart';
import '../voice/voice_settings.dart';

/// Opens the voice settings as a HUD sheet.
Future<void> showVoiceSettingsSheet(BuildContext context) =>
    showHudBottomSheet<void>(
      context,
      title: 'Voice',
      builder: (_) => const SingleChildScrollView(child: VoiceSettingsPanel()),
    );

/// Voice preferences: input on/off, auto-speak, voice, rate, pitch, wake on
/// open and offline recognition. Voices are listed lazily from the device
/// TTS engine (nothing is loaded until this panel is shown).
class VoiceSettingsPanel extends ConsumerStatefulWidget {
  const VoiceSettingsPanel({super.key});

  @override
  ConsumerState<VoiceSettingsPanel> createState() => _VoiceSettingsPanelState();
}

class _VoiceSettingsPanelState extends ConsumerState<VoiceSettingsPanel> {
  List<TtsVoice>? _voices;

  @override
  void initState() {
    super.initState();
    unawaited(_loadVoices());
  }

  Future<void> _loadVoices() async {
    final v = await ref.read(speechSynthProvider).voices();
    if (!mounted) return;
    final en = v.where((x) => x.locale.toLowerCase().startsWith('en')).toList()
      ..sort((a, b) {
        int rank(TtsVoice x) {
          final l = x.locale.replaceAll('_', '-').toLowerCase();
          return (l == 'en-gb' ? 0 : 1) + (x.network ? 2 : 0);
        }

        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : a.name.compareTo(b.name);
      });
    setState(() => _voices = en.take(24).toList());
  }

  Future<void> _update(VoiceSettings Function(VoiceSettings) f) async {
    Haptics.selection();
    await ref.read(voiceSettingsRepositoryProvider).update(f);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(voiceSettingsProvider).value ?? const VoiceSettings();
    final voice = ref.watch(voiceControllerProvider);
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;

    Widget toggle(String title, String sub, bool v, ValueChanged<bool> on) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.titleSmall),
                    Text(
                      sub,
                      style: t.bodySmall?.copyWith(color: hud.textMuted),
                    ),
                  ],
                ),
              ),
              HudToggle(value: v, onChanged: on, semanticLabel: title),
            ],
          ),
        );

    final picked = s.voiceName == null
        ? null
        : TtsVoice(s.voiceName!, s.voiceLocale ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        toggle(
          'Voice control',
          'Push-to-talk and spoken replies',
          s.enabled,
          (v) => _update((x) => x.copyWith(enabled: v)),
        ),
        const SizedBox(height: AppSpacing.md),
        Text('SPEAK REPLIES', style: hud.label(size: 11)),
        const SizedBox(height: AppSpacing.sm),
        SegmentedHud<AutoSpeak>(
          segments: [
            for (final a in AutoSpeak.values)
              HudSegment(value: a, label: a.label),
          ],
          value: s.autoSpeak,
          onChanged: s.enabled
              ? (v) => _update((x) => x.copyWith(autoSpeak: v))
              : null,
        ),
        const SizedBox(height: 6),
        Text(
          'Only a short summary is spoken — never tables, lists or tool chatter.',
          style: hud.mono(size: 10.5),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('VOICE', style: hud.label(size: 11)),
        const SizedBox(height: AppSpacing.sm),
        if (_voices == null)
          const ScanlineLoader(lines: 2)
        else if (_voices!.isEmpty)
          Text(
            'No English text-to-speech voices found. Install Google '
            'Speech Services (or another TTS engine) in Android settings.',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          )
        else
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                HudChip(
                  label: 'Auto · British',
                  selected: picked == null,
                  onTap: () => _update(
                    (x) => x.copyWith(
                      voiceName: () => null,
                      voiceLocale: () => null,
                    ),
                  ),
                ),
                for (final v in _voices!) ...[
                  const SizedBox(width: 6),
                  HudChip(
                    label: v.label,
                    uppercase: false,
                    selected: picked?.name == v.name,
                    onTap: () => _update(
                      (x) => x.copyWith(
                        voiceName: () => v.name,
                        voiceLocale: () => v.locale,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        _SliderRow(
          label: 'Rate',
          value: s.rate,
          min: 0.3,
          max: 0.7,
          display: '${(s.rate / 0.5 * 100).round()}%',
          onChanged: (v) => ref
              .read(voiceSettingsRepositoryProvider)
              .update((x) => x.copyWith(rate: v)),
        ),
        _SliderRow(
          label: 'Pitch',
          value: s.pitch,
          min: 0.7,
          max: 1.3,
          display: s.pitch.toStringAsFixed(2),
          onChanged: (v) => ref
              .read(voiceSettingsRepositoryProvider)
              .update((x) => x.copyWith(pitch: v)),
        ),
        const SizedBox(height: AppSpacing.sm),
        HudButton.secondary(
          label: voice.speaking ? 'Stop' : 'Test voice',
          icon: voice.speaking ? Icons.stop_rounded : Icons.graphic_eq_rounded,
          onPressed: () {
            final c = ref.read(voiceControllerProvider.notifier);
            if (voice.speaking) {
              unawaited(c.stopSpeaking());
            } else {
              unawaited(
                c.speak(
                  'Good evening. All systems are online, and I am at your '
                  'service.',
                  s.copyWith(enabled: true),
                ),
              );
            }
          },
        ),
        const SizedBox(height: AppSpacing.lg),
        toggle(
          'Wake on open',
          'Start listening as soon as the Coach opens',
          s.wakeOnOpen,
          (v) => _update((x) => x.copyWith(wakeOnOpen: v)),
        ),
        toggle(
          'Prefer on-device recognition',
          'Keeps audio on the phone; fails if no offline model is installed',
          s.preferOffline,
          (v) => _update((x) => x.copyWith(preferOffline: v)),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Audio is never recorded or stored. Your phone\'s speech service '
          'turns speech into text; only the text reaches the coach.',
          style: t.bodySmall?.copyWith(color: hud.textMuted),
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(label.toUpperCase(), style: hud.label(size: 11)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: 20,
            onChanged: (v) {
              Haptics.selection();
              onChanged(v);
            },
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: hud.mono(size: 11, color: hud.text),
          ),
        ),
      ],
    );
  }
}
