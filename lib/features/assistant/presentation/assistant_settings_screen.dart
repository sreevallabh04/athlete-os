import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class AssistantSettingsScreen extends StatelessWidget {
  const AssistantSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Messaging assistant',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
