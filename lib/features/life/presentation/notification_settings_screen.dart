import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class NotificationSettingsScreen extends StatelessWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Notifications',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
