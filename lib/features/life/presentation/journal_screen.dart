import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class JournalScreen extends StatelessWidget {
  const JournalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Journal',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
