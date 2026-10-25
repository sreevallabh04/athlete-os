import 'package:athlete_os/app/paths.dart';
import 'package:athlete_os/features/surfaces/domain/deep_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveDeepLink allowlist', () {
    test('maps every shortcut / widget link to its screen', () {
      expect(
        resolveDeepLink('athleteos://open/hydration?quickAdd=1'),
        const DeepLinkTarget(
          AppPaths.hydration,
          action: DeepLinkAction.quickAddWater,
        ),
      );
      expect(
        resolveDeepLink('athleteos://open/hydration'),
        const DeepLinkTarget(AppPaths.hydration),
      );
      expect(
        resolveDeepLink('athleteos://open/nutrition/add'),
        const DeepLinkTarget(AppPaths.addFood),
      );
      expect(
        resolveDeepLink('athleteos://open/coach?listen=1'),
        const DeepLinkTarget('/coach?listen=1', mode: DeepLinkMode.go),
      );
      expect(
        resolveDeepLink('athleteos://open/session'),
        const DeepLinkTarget(AppPaths.program),
      );
      expect(
        resolveDeepLink('athleteos://open/train/program'),
        const DeepLinkTarget(AppPaths.program),
      );
      expect(
        resolveDeepLink('athleteos://open/today'),
        const DeepLinkTarget(AppPaths.today, mode: DeepLinkMode.go),
      );
      expect(
        resolveDeepLink('athleteos://open/steps'),
        const DeepLinkTarget(AppPaths.steps),
      );
      expect(
        resolveDeepLink('athleteos://open/nutrition'),
        const DeepLinkTarget(AppPaths.nutrition, mode: DeepLinkMode.go),
      );
      expect(
        resolveDeepLink('athleteos://open/routine'),
        const DeepLinkTarget(AppPaths.routine),
      );
    });

    test('every allowlisted path resolves to a known app path', () {
      const known = {
        AppPaths.today,
        AppPaths.train,
        AppPaths.nutrition,
        AppPaths.coach,
        AppPaths.life,
        AppPaths.addFood,
        AppPaths.hydration,
        AppPaths.steps,
        AppPaths.healthOverview,
        AppPaths.program,
        AppPaths.routine,
        AppPaths.assistant,
      };
      for (final p in allowedDeepLinkPaths) {
        final t = resolveDeepLink(deepLinkUri(p).toString());
        expect(t, isNotNull, reason: p);
        expect(known, contains(Uri.parse(t!.location).path), reason: p);
      }
    });

    test('scheme and host are case-insensitive, trailing slash ok', () {
      expect(
        resolveDeepLink('ATHLETEOS://OPEN/Steps/'),
        const DeepLinkTarget(AppPaths.steps),
      );
    });

    test('rejects other schemes, hosts and the OAuth callback host', () {
      for (final raw in [
        null,
        '',
        'https://open/hydration',
        'athleteos://localhost/strava?code=abc',
        'athleteos://localhost/auth',
        'athleteos://evil/hydration',
        'athleteos:/open/hydration',
        'athleteos://user@open/hydration',
        'athleteos://open:8080/hydration',
        'athleteos://open',
        'athleteos://open/',
        'intent://open/hydration#Intent;scheme=athleteos;end',
      ]) {
        expect(resolveDeepLink(raw), isNull, reason: raw);
      }
    });

    test('rejects routes outside the allowlist and path tricks', () {
      for (final raw in [
        'athleteos://open/settings/privacy',
        'athleteos://open/assistant/settings',
        'athleteos://open/workout/123',
        'athleteos://open/running/activity/1',
        'athleteos://open/dev/gallery',
        'athleteos://open/onboarding',
        'athleteos://open/hydration/../settings',
        'athleteos://open/../settings/privacy',
        'athleteos://open/hydration/extra',
        'athleteos://open/%2Fsettings',
      ]) {
        expect(resolveDeepLink(raw), isNull, reason: raw);
      }
    });

    test('drops unknown query parameters and invalid values', () {
      expect(
        resolveDeepLink('athleteos://open/coach?listen=1&prompt=delete+all'),
        const DeepLinkTarget('/coach?listen=1', mode: DeepLinkMode.go),
      );
      expect(
        resolveDeepLink('athleteos://open/coach?listen=yes'),
        const DeepLinkTarget(AppPaths.coach, mode: DeepLinkMode.go),
      );
      expect(
        resolveDeepLink('athleteos://open/coach?listen=1&listen=1'),
        const DeepLinkTarget(AppPaths.coach, mode: DeepLinkMode.go),
      );
      expect(
        resolveDeepLink('athleteos://open/nutrition/add?meal=Lunch&q=x'),
        const DeepLinkTarget('/nutrition/add?meal=lunch'),
      );
      expect(
        resolveDeepLink('athleteos://open/nutrition/add?meal=brunch'),
        const DeepLinkTarget(AppPaths.addFood),
      );
      expect(
        resolveDeepLink('athleteos://open/hydration?quickAdd=500'),
        const DeepLinkTarget(AppPaths.hydration),
      );
      // Parameters are only accepted on the route that defines them.
      expect(
        resolveDeepLink('athleteos://open/steps?listen=1'),
        const DeepLinkTarget(AppPaths.steps),
      );
    });

    test('rejects oversized input', () {
      final long = 'athleteos://open/hydration?x=${'a' * 600}';
      expect(resolveDeepLink(long), isNull);
    });

    test('deepLinkUri builds the native format', () {
      expect(
        deepLinkUri('hydration', {'quickAdd': '1'}).toString(),
        'athleteos://open/hydration?quickAdd=1',
      );
      expect(
        deepLinkUri('nutrition/add').toString(),
        'athleteos://open/nutrition/add',
      );
    });
  });
}
