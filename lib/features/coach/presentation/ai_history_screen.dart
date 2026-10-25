import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class AiHistoryScreen extends StatelessWidget {
  const AiHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'AI activity log',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
