import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Settings',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
