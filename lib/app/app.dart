import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../data/repositories/settings_repository.dart';
import 'router.dart';

class AthleteOsApp extends ConsumerWidget {
  const AthleteOsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final mode = ref.watch(themeModeSettingProvider).value ?? 'dark';
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
    );
  }
}
