import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class WorkoutDetailScreen extends StatelessWidget {
  const WorkoutDetailScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Workout',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
