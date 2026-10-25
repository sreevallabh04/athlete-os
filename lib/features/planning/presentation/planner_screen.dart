import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class PlannerScreen extends StatelessWidget {
  const PlannerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Plan your day',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
