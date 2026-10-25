import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class LifeScreen extends StatelessWidget {
  const LifeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Life',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
