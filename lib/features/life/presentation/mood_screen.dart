import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class MoodScreen extends StatelessWidget {
  const MoodScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Mood',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
