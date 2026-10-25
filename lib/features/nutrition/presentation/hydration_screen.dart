import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class HydrationScreen extends StatelessWidget {
  const HydrationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Hydration',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
