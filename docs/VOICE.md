# JARVIS voice: push-to-talk and spoken replies

The Coach can be driven by voice: hold (or tap) the mic, speak, release, and
JARVIS answers on screen and, optionally, out loud. Everything here runs on
the phone. Audio is never recorded, stored or uploaded by Athlete OS.

## Packages

| Package | Version | Used for |
|---|---|---|
| [`speech_to_text`](https://pub.dev/packages/speech_to_text) | **7.5.0** (pinned) | Android `SpeechRecognizer`: partial results, final transcript, RMS sound level |
| [`flutter_tts`](https://pub.dev/packages/flutter_tts) | **4.2.5** (pinned) | Android `TextToSpeech`: voices, rate, pitch, word-progress callbacks |

Both are maintained, null-safe and compatible with Dart 3.13 / Flutter 3.47
(`speech_to_text` needs Flutter ≥ 3.44). They are wrapped behind two ports in
`lib/features/coach/voice/speech_ports.dart`:

* `SpeechRecognizerPort` → `PluginSpeechRecognizer`
* `SpeechSynthPort` → `PluginSpeechSynth`

Tests and screenshots override `speechRecognizerProvider` /
`speechSynthProvider` with `FakeRecognizer` / `FakeSynth`
(`test/features/coach/voice_fakes.dart`), so no platform channel is touched.
Every plugin call is wrapped in try/catch: a missing engine degrades to an
explanation, never a crash.

## Android manifest (additive)

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<queries>
  <intent><action android:name="android.speech.RecognitionService" /></intent>
  <intent><action android:name="android.intent.action.TTS_SERVICE" /></intent>
</queries>
```

The `<queries>` entries are required on Android 11+ for the app to see the
installed recogniser and TTS engines (package visibility).

## Permission flow

1. Nothing is requested at install or launch.
2. The **first** mic tap (or hold, or orb tap) opens a HUD sheet explaining
   what happens: mic only live while held/tapped, the phone's speech service
   transcribes, only text reaches the coach, no audio stored.
3. **Continue** → `SpeechToText.initialize()` → Android's own RECORD_AUDIO
   dialog. *Not now* changes nothing.
4. Outcomes:
   * granted → listening starts immediately;
   * denied → "Microphone is off" sheet with **Open app settings**
     (`AssistantPlatform.openAppDetailsSettings`);
   * no recogniser (`initialize` fails although the permission is granted) →
     "No speech recogniser" sheet (install/enable Google's speech services).
5. The sheet is shown once (`micExplained` in the voice settings). If
   Android already has the permission, it is skipped.

## Interaction

| Gesture | Result |
|---|---|
| Tap mic / tap core orb | Start listening; tap again to stop and send |
| Press and hold mic or orb | Talk while held; release sends |
| Tap orb while speaking | Stop speaking |
| Say "Brief me" / "Review my day" | Runs the local briefing instead of a model call |

While listening, the orb switches to its **listening** state driven by the
real microphone level (Android RMS dB, normalised `(dB + 2) / 12` to 0..1),
the halo swells with the voice, the composer shows the live partial
transcript and the header reads `LISTENING · RELEASE OR TAP TO SEND`.
Recognition uses `ListenMode.dictation`, partial results, a 45 s ceiling and
3 s pause detection. *Prefer on-device recognition* sets `onDevice: true`
(fails cleanly if no offline model is installed).

Haptics: medium on listen start, light on stop, light when speech starts,
success when an answer lands, warning on a fault.

## Spoken replies

`VoiceController.speak` never reads raw answers. `speakableSummary()`
(unit-tested) strips markdown, skips tables and code, reads at most three
bullets and caps the result at ~260 characters, cutting at a sentence or
word boundary. Tool chatter ("Scanning nutrition log…") is never spoken.

**Speak replies** setting:

| Value | Behaviour |
|---|---|
| Off | Never speaks automatically (the waveform icon on each reply still reads it on demand) |
| When I speak (default) | Speaks answers to turns that were started by voice |
| Always | Speaks every final answer and briefing |

TTS progress callbacks drive the orb: the speaking arc fills with progress
and each spoken word emits a ripple (`wordTick`). If an engine never sends a
completion callback, a safety timeout (8 s + 1 s per 8 characters) ends the
speaking state.

### Voice selection

Default: the best **British English** voice available — `en-GB`, on-device,
preferring Google's male voices (`…-rjs-…`, then `…-gbd-…`), then any `en-GB`,
then any English voice, else the engine default with `setLanguage('en-GB')`
(`pickDefaultVoice`, unit-tested). Users can pick any English voice in
Systems › Voice. Defaults: rate 0.46 (flutter_tts scale, 0.5 = normal; a calm
92 %), pitch 0.92.

## Settings

Stored as one JSON object under AppSettings key `ai.voice`
(`VoiceSettings`, `lib/features/coach/voice/voice_settings.dart`). Editable
in the Coach (Systems › Voice) and in AI settings › Voice.

| Field | Default | Meaning |
|---|---|---|
| `enabled` | true | Push-to-talk and spoken replies at all |
| `auto_speak` | `voice` | off / voice / always (see above) |
| `voice_name`, `voice_locale` | null | Chosen TTS voice (null = auto British) |
| `rate` | 0.46 | 0.2–0.9 |
| `pitch` | 0.92 | 0.6–1.4 |
| `wake_on_open` | **false** | Start listening when the Coach opens — only if the mic permission was already granted (never prompts) and the backend is ready |
| `prefer_offline` | false | Ask the recogniser for on-device recognition |
| `mic_explained` | false | The explanation sheet was accepted once |

## Verify on a device

1. First mic tap shows the sheet; *Continue* shows Android's dialog.
2. Hold the mic, say "how much protein do I have left", release: the
   transcript is sent, JARVIS answers, and (default setting) speaks a short
   summary in a British voice.
3. Tap the orb while it speaks: speech stops.
4. Deny the permission (App info › Permissions) and tap the mic: the
   "Microphone is off" sheet appears with *Open app settings*.
5. Systems › Voice › Test voice; change the voice and rate; switch *Speak
   replies* to Always and use a quick command.
