import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class HealthOverviewScreen extends StatelessWidget {
  const HealthOverviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Health',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
