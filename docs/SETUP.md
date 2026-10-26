# Development environment setup

This records the environment that was actually installed and verified for Athlete OS on
**2026-10-25**, plus how to reproduce it.

## Machine inspected

| Item | Value |
|---|---|
| OS | Windows 11 Pro 25H2 (10.0.26200), x64 |
| CPU / RAM | Intel Core Ultra 7 265U, 31.5 GB |
| Shells | PowerShell 5.1, Git Bash |
| Admin rights | **No** (everything below is installed per-user, no admin needed) |
| Free disk | C: 104 GB, D: 175 GB (toolchains placed on D:) |
| Pre-existing | Git, Node.js, Python 3.12, Chrome, Visual Studio 2026 |
| Missing before setup | Flutter, Dart, JDK, Android SDK, Android Studio, emulator |

## Installed toolchain (verified)

| Component | Version | Location | Source |
|---|---|---|---|
| Flutter (stable) | 3.47.8 (framework 737ba8f885) | `D:\dev\flutter` | `git clone https://github.com/flutter/flutter.git -b stable` (official) |
| Dart | 3.13.7 | bundled with Flutter | |
| JDK | Eclipse Temurin 21.0.12.1+1 LTS | `D:\dev\jdk-21` | Adoptium API zip, SHA-256 verified |
| Android cmdline-tools | build 15859902 | `D:\dev\android-sdk\cmdline-tools\latest` | dl.google.com, SHA-256 `90ae805d…fb04a` verified |
| Android platform-tools | 37.0.1 | `D:\dev\android-sdk\platform-tools` | sdkmanager |
| Android platform | android-36 | `D:\dev\android-sdk\platforms` | sdkmanager |
| Build-tools | 36.1.0 | `D:\dev\android-sdk\build-tools` | sdkmanager |
| Android Emulator | 37.2.12 | `D:\dev\android-sdk\emulator` | sdkmanager |
| Gradle / AGP / Kotlin | 9.3.1 / 9.1.0 / 2.4.0 | project wrapper | Flutter template |

The NDK is downloaded automatically by Gradle on the first build if a plugin needs it.
All Android SDK licences were accepted (`sdkmanager --licenses`).

## Environment variables (persisted for the current user)

Set with `[Environment]::SetEnvironmentVariable(..., 'User')`:

```
JAVA_HOME   = D:\dev\jdk-21
ANDROID_HOME = D:\dev\android-sdk
Path       += D:\dev\flutter\bin;D:\dev\android-sdk\platform-tools;
              D:\dev\android-sdk\cmdline-tools\latest\bin;D:\dev\android-sdk\emulator;D:\dev\jdk-21\bin
```

Flutter is also pointed at the SDK/JDK explicitly:

```
flutter config --jdk-dir D:\dev\jdk-21 --android-sdk D:\dev\android-sdk
flutter config --no-analytics
```

Open a **new** terminal (or restart VS Code) for the PATH change to take effect.

## `flutter doctor -v` result

- ✓ Flutter 3.47.8 stable
- ✓ Android toolchain (SDK 36.1.0, JDK 21, all licences accepted)
- ✓ Chrome, Network resources
- ! Visual Studio missing C++ components — **only needed for Windows desktop builds; irrelevant
  for Android.** Ignore unless you want a Windows build.
- ! A physical device (`QWINNFNJUSTCW8KJ`) was detected but **not authorised** — see below.

Android Studio is **not** installed. It is optional: the command-line SDK is sufficient to build
and run. Install it later (per-user installer from developer.android.com/studio) if you want the
layout inspector or a GUI AVD manager.

## Running on your Samsung Galaxy (recommended)

1. Settings › About phone › Software information › tap **Build number** 7× to enable Developer options.
2. Settings › Developer options › enable **USB debugging**.
3. Connect via USB, unlock the phone and accept **Allow USB debugging** (tick *Always allow*).
4. `adb devices` should show the device as `device` (not `unauthorized`).
5. From the project folder:

```powershell
flutter run --dart-define-from-file=config/dev.json   # or omit the flag for local-only mode
```

Wireless debugging (Android 11+): Developer options › Wireless debugging › *Pair device with
pairing code*, then `adb pair <ip:port>` and `adb connect <ip:port>`.

## Emulator (optional)

The emulator needs a hardware hypervisor. This machine reports a hypervisor present, but the
Windows Hypervisor Platform feature must be enabled, which **requires admin rights**:

```powershell
# Run in an elevated PowerShell, then reboot
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
```

Then create an AVD:

```powershell
sdkmanager "system-images;android-36;google_apis_playstore;x86_64"
avdmanager create avd -n athlete_os -k "system-images;android-36;google_apis_playstore;x86_64" -d pixel_8
emulator -avd athlete_os
```

Health Connect data is far more meaningful on the real phone + Galaxy Watch, so the physical
device is the recommended target.

## Client configuration

Public identifiers are passed at build time:

```powershell
copy config\dev.example.json config\dev.json   # config/dev.json is git-ignored
flutter run --dart-define-from-file=config/dev.json
```

Server secrets (AI provider keys, Strava client secret) never go in the app — see
`.env.example`, `docs/INTEGRATIONS.md` and `docs/AI_AGENT.md`.

## Project commands

```powershell
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # only after changing Drift tables
dart format lib test
flutter analyze
flutter test
flutter build apk --debug      # output: build\app\outputs\flutter-apk\app-debug.apk
```

## Device notes (OPPO CPH2251, Android 13, ColorOS)

- Health Connect app (`com.google.android.apps.healthdata`), Google TTS and the Google speech
  recogniser are installed — voice and Health Connect work without extra installs.
- ColorOS blocks `adb shell settings put` (screen timeout / stay-awake) without
  "Disable permission monitoring"; toggle *Developer options › Stay awake* manually if needed.
- Battery: Settings › Battery › App battery management › Athlete OS › allow background activity
  and auto-launch, and lock the app in Recents, so reminders and the assistant keep running.

## Troubleshooting notes from this setup

- `sdkmanager` stalled once while installing several packages in one invocation (a 0-byte
  download in `.temp`). Killing it and installing packages one at a time fixed it.
- Piping `y` into `sdkmanager --licenses` from PowerShell does not work; use Git Bash:
  `yes | cmd //c "sdkmanager.bat --licenses"`.
- Kotlin incremental compilation breaks when the pub cache (C:) and build output (D:) are on
  different drives: `kotlin.incremental=false` is set in `android/gradle.properties`.
- The project lives in a path with a space (`D:\Gym App`); Gradle handles this, but toolchains
  were deliberately installed to space-free paths.
