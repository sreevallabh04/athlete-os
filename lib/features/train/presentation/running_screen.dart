import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class RunningScreen extends StatelessWidget {
  const RunningScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Running',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
