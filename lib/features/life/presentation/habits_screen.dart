import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class HabitsScreen extends StatelessWidget {
  const HabitsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Habits',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
