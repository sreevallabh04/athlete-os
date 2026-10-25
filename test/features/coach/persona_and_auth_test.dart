import 'dart:async';

import 'package:athlete_os/data/repositories/settings_repository.dart';
import 'package:athlete_os/features/coach/agent/system_prompt.dart';
import 'package:athlete_os/features/coach/data/ai_preferences.dart';
import 'package:athlete_os/features/coach/data/coach_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';
import 'coach_test_utils.dart';

class _FakeAuth implements CoachAuth {
  _FakeAuth({this.configured = true, this.fail = false});
  final bool configured;
  bool signedIn = false;
  final bool fail;
  int anonymousCalls = 0;

  @override
  CoachAuthState get current => CoachAuthState(
    configured: configured,
    userId: signedIn ? 'u1' : null,
    isAnonymous: signedIn,
  );
  @override
  Stream<CoachAuthState> changes() => Stream.value(current);
  @override
  Future<void> signInAnonymously() async {
    anonymousCalls++;
    if (fail) throw StateError('offline');
    signedIn = true;
  }

  @override
  Future<void> sendEmailCode(String email) async {}
  @override
  Future<void> verifyEmailCode(String email, String code) async {}
  @override
  Future<void> signOut() async => signedIn = false;
}

void main() {
  group('persona', () {
    test('defaults to JARVIS addressing Sreevallabh; rules kept', () async {
      final db = newTestDb();
      addTearDown(db.close);
      final prompt = buildSystemPrompt(
        await loadSystemPromptInputs(db, SettingsRepository(db), testNow),
      );
      expect(prompt, startsWith('Persona:'));
      expect(prompt, contains('JARVIS'));
      expect(prompt, contains('"Sreevallabh"'));
      expect(prompt, contains('British butler'));
      expect(prompt, contains('rules below always take precedence'));
      expect(prompt, contains('Never invent'));
      expect(prompt, contains('diuretics'));
      expect(prompt, contains('self-harm'));
      expect(prompt.length, lessThan(12000));
    });

    test('custom persona from ai.persona; empty = plain coach', () async {
      final db = newTestDb();
      addTearDown(db.close);
      final settings = SettingsRepository(db);
      await settings.set(AiSettingKeys.persona, 'You are FRIDAY. Be upbeat.');
      var prompt = buildSystemPrompt(
        await loadSystemPromptInputs(db, settings, testNow),
      );
      expect(prompt, contains('You are FRIDAY'));
      expect(prompt, isNot(contains('JARVIS')));

      await settings.set(AiSettingKeys.persona, '   ');
      prompt = buildSystemPrompt(
        await loadSystemPromptInputs(db, settings, testNow),
      );
      expect(prompt, startsWith('You are Athlete OS Coach'));
      expect(prompt, isNot(contains('JARVIS')));
    });

    test('resolvePersona caps length and defaults when unset', () {
      expect(resolvePersona(null), defaultAiPersona);
      expect(resolvePersona('x' * 5000).length, maxPersonaChars);
      expect(resolvePersona('  hi  '), 'hi');
    });
  });

  group('ensureAnonymousSession', () {
    test('signs in when configured, signed out and not opted out', () async {
      final db = newTestDb();
      addTearDown(db.close);
      final auth = _FakeAuth();
      expect(await ensureAnonymousSession(auth, SettingsRepository(db)), true);
      expect(auth.signedIn, isTrue);
      // Already signed in: no second call.
      expect(await ensureAnonymousSession(auth, SettingsRepository(db)), false);
      expect(auth.anonymousCalls, 1);
    });

    test('respects explicit opt-out and unconfigured builds', () async {
      final db = newTestDb();
      addTearDown(db.close);
      final settings = SettingsRepository(db);
      await settings.set(autoAnonymousSignInKey, false);
      final auth = _FakeAuth();
      expect(await ensureAnonymousSession(auth, settings), false);
      expect(auth.anonymousCalls, 0);
      final un = _FakeAuth(configured: false);
      expect(await ensureAnonymousSession(un, SettingsRepository(db)), false);
      expect(un.anonymousCalls, 0);
    });

    test('never throws when sign-in fails (offline)', () async {
      final db = newTestDb();
      addTearDown(db.close);
      final auth = _FakeAuth(fail: true);
      expect(await ensureAnonymousSession(auth, SettingsRepository(db)), false);
      expect(auth.anonymousCalls, 1);
    });
  });

  test('groq is a known provider id', () {
    expect(aiProviderIds, contains('groq'));
    expect(aiProviderLabels['groq'], 'Groq');
  });
}
