import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/haptics/haptics.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/hud_background.dart';
import '../data/repositories/settings_repository.dart';
import 'boot/boot_sequence.dart';
import 'router.dart';

/// Global haptics switch (AppSettings key `ui.haptics`, default on).
final hapticsEnabledProvider = StreamProvider<bool>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watch<bool>(Haptics.settingKey)
      .map((v) => v ?? true),
);

class AthleteOsApp extends ConsumerWidget {
  const AthleteOsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _registerFontLicenses();
    final router = ref.watch(routerProvider);
    final mode = ref.watch(themeModeSettingProvider).value ?? 'dark';
    final haptics = ref.watch(hapticsEnabledProvider).value;
    if (haptics != null) Haptics.enabled = haptics;
    return MaterialApp.router(
      title: 'Athlete OS',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: switch (mode) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      },
      routerConfig: router,
      builder: (context, child) =>
          HudAppFrame(child: child ?? const SizedBox()),
    );
  }
}

/// App-wide chrome under/over the navigator: the living HUD background,
/// edge-to-edge system bars and the cold-start boot sequence.
class HudAppFrame extends StatefulWidget {
  const HudAppFrame({super.key, required this.child});
  final Widget child;

  @override
  State<HudAppFrame> createState() => _HudAppFrameState();
}

class _HudAppFrameState extends State<HudAppFrame> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final icons = dark ? Brightness.light : Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: icons,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness: icons,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const HudBackground(),
          BootGate(child: widget.child),
        ],
      ),
    );
  }
}

bool _licensesRegistered = false;

void _registerFontLicenses() {
  if (_licensesRegistered) return;
  _licensesRegistered = true;
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(const [
      'Inter',
      'JetBrains Mono',
      'Rajdhani',
    ], text);
  });
}
