import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class TrainScreen extends StatelessWidget {
  const TrainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Train',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
