import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Today',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
