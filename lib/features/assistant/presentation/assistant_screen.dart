import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class AssistantScreen extends StatelessWidget {
  const AssistantScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Assistant',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
