import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Calendar',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
