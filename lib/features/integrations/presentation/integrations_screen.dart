import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class IntegrationsScreen extends StatelessWidget {
  const IntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Integrations',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
