import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class CompetitionScreen extends StatelessWidget {
  const CompetitionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Competition prep',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
