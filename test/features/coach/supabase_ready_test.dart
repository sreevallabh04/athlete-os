import 'package:athlete_os/features/coach/data/ai_backend.dart';
import 'package:athlete_os/features/coach/data/coach_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Regression: on a slow cold start the first frame can be shown before
  // Supabase finishes initialising. Providers read during that window used to
  // cache "unconfigured" forever (coach stuck on "Awaiting credentials").
  test('readiness is reactive: providers re-evaluate when init completes', () {
    final container = ProviderContainer();
    addTearDown(() {
      CoachSupabase.readyNotifier.value = false;
      container.dispose();
    });

    expect(container.read(supabaseReadyProvider), isFalse);
    expect(container.read(coachAuthProvider), isA<UnconfiguredCoachAuth>());

    var rebuilt = false;
    container.listen(supabaseReadyProvider, (_, next) => rebuilt = next);
    CoachSupabase.readyNotifier.value = true;
    expect(container.read(supabaseReadyProvider), isTrue);
    expect(rebuilt, isTrue);
  });

  test('backend stays honest while Supabase is not ready', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(aiBackendClientProvider).state,
      AiBackendState.unconfigured,
    );
  });
}
