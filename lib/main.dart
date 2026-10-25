import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/bootstrap.dart';
import 'app/overrides.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer(overrides: appOverrides());
  await bootstrap(container);
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const AthleteOsApp(),
    ),
  );
}
