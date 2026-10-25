import 'package:athlete_os/app/paths.dart';
import 'package:athlete_os/features/surfaces/application/deep_link_router.dart';
import 'package:athlete_os/features/surfaces/domain/deep_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  GoRouter testRouter() {
    GoRoute page(String path) => GoRoute(
      path: path,
      builder: (context, state) => Scaffold(body: Text('page ${state.uri}')),
    );
    return GoRouter(
      initialLocation: AppPaths.today,
      routes: [
        page(AppPaths.today),
        page(AppPaths.coach),
        page(AppPaths.hydration),
        page(AppPaths.addFood),
        page(AppPaths.program),
        page(AppPaths.settings),
        page(AppPaths.privacy),
      ],
    );
  }

  Future<(GoRouter, List<DeepLinkAction>, DeepLinkRouter)> pump(
    WidgetTester tester,
  ) async {
    final router = testRouter();
    final actions = <DeepLinkAction>[];
    final links = DeepLinkRouter(router: () => router, onAction: actions.add);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    return (router, actions, links);
  }

  String location(GoRouter r) => r.state.uri.toString();

  testWidgets('pushes allowlisted screens and runs the quick-add action', (
    tester,
  ) async {
    final (router, actions, links) = await pump(tester);

    expect(links.open('athleteos://open/hydration?quickAdd=1'), isTrue);
    await tester.pumpAndSettle();
    expect(location(router), AppPaths.hydration);
    expect(actions, [DeepLinkAction.quickAddWater]);

    // Back returns to where the user was.
    router.pop();
    await tester.pumpAndSettle();
    expect(location(router), AppPaths.today);
  });

  testWidgets('tab targets are switched to with sanitised params', (
    tester,
  ) async {
    final (router, actions, links) = await pump(tester);
    expect(links.open('athleteos://open/coach?listen=1&prompt=x'), isTrue);
    await tester.pumpAndSettle();
    expect(location(router), '/coach?listen=1');
    expect(find.text('page /coach?listen=1'), findsOneWidget);
    expect(actions, isEmpty);
  });

  testWidgets('the same screen is not stacked twice', (tester) async {
    final (router, _, links) = await pump(tester);
    links.open('athleteos://open/session');
    await tester.pumpAndSettle();
    links.open('athleteos://open/session');
    await tester.pumpAndSettle();
    expect(location(router), AppPaths.program);
    router.pop();
    await tester.pumpAndSettle();
    expect(location(router), AppPaths.today);
  });

  testWidgets('never navigates for links outside the allowlist', (
    tester,
  ) async {
    final (router, actions, links) = await pump(tester);
    for (final raw in [
      'athleteos://open/settings/privacy',
      'athleteos://localhost/strava?code=1',
      'athleteos://open/../settings',
      'https://example.com/today',
    ]) {
      expect(links.open(raw), isFalse, reason: raw);
    }
    await tester.pumpAndSettle();
    expect(location(router), AppPaths.today);
    expect(actions, isEmpty);
  });
}
