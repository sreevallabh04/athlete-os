import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class StepsScreen extends StatelessWidget {
  const StepsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Steps',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
