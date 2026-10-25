import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class HealthStatusScreen extends StatelessWidget {
  const HealthStatusScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Health Connect',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
