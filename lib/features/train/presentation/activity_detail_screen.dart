import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class ActivityDetailScreen extends StatelessWidget {
  const ActivityDetailScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Activity',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
