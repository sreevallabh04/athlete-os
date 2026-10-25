import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Standard scrollable page with a large collapsing title. Use for every
/// top-level and secondary screen so spacing stays consistent.
class AppPage extends StatelessWidget {
  const AppPage({
    super.key,
    required this.title,
    required this.children,
    this.actions,
    this.subtitle,
    this.onRefresh,
    this.floatingActionButton,
    this.showBack,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final List<Widget>? actions;
  final Future<void> Function()? onRefresh;
  final Widget? floatingActionButton;

  /// Defaults to automatic (shows when the route can pop).
  final bool? showBack;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    Widget scroll = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        SliverAppBar.large(
          automaticallyImplyLeading: showBack ?? true,
          title: Text(title),
          actions: actions,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
        ),
        if (subtitle != null)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
            sliver: SliverToBoxAdapter(
              child: Text(
                subtitle!,
                style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.sm,
            AppSpacing.gutter,
            AppSpacing.xxxl * 2,
          ),
          sliver: SliverList.list(children: children),
        ),
      ],
    );
    if (onRefresh != null) {
      scroll = RefreshIndicator(onRefresh: onRefresh!, child: scroll);
    }
    return Scaffold(
      body: SafeArea(bottom: false, child: scroll),
      floatingActionButton: floatingActionButton,
    );
  }
}

/// Adds vertical spacing between a list of widgets.
List<Widget> spaced(List<Widget> children, {double gap = AppSpacing.md}) {
  final out = <Widget>[];
  for (var i = 0; i < children.length; i++) {
    if (i > 0) out.add(SizedBox(height: gap));
    out.add(children[i]);
  }
  return out;
}
