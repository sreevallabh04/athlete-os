import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

class AddFoodScreen extends StatelessWidget {
  const AddFoodScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppPage(
      title: 'Add food',
      children: [EmptyState(icon: Icons.construction, title: 'Coming soon')],
    );
  }
}
