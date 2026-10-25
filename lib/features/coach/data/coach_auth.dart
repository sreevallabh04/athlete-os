import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/env.dart';
import '../../../core/util/redact.dart';
import '../../../data/repositories/settings_repository.dart';

/// Owns Supabase initialisation for the app. Initialised only when the build
/// was given a Supabase URL + anon key; otherwise every AI surface reports
/// "awaiting credentials" and never pretends to work.
abstract final class CoachSupabase {
  static bool _ready = false;
  static bool get ready => _ready;

  static Future<void> init() async {
    if (_ready || !Env.hasSupabase) return;
    try {
      await Supabase.initialize(
        url: Env.supabaseUrl,
        publishableKey: Env.supabaseAnonKey,
      );
      _ready = true;
    } catch (e) {
      debugPrint('Supabase init failed: ${redactSecrets(e.toString())}');
    }
  }
}

class CoachAuthState {
  const CoachAuthState({
    required this.configured,
    this.userId,
    this.email,
    this.isAnonymous = false,
  });

  const CoachAuthState.unconfigured() : this(configured: false);

  final bool configured;
  final String? userId;
  final String? email;
  final bool isAnonymous;

  bool get signedIn => userId != null;
}

/// Sign-in for the AI backend: anonymous (device-bound) or email OTP.
///
/// When the current user is anonymous, [sendEmailCode] LINKS the email to
/// that same account (usage history is kept); if the email already belongs
/// to another account it falls back to signing in to that account.
abstract interface class CoachAuth {
  CoachAuthState get current;
  Stream<CoachAuthState> changes();
  Future<void> signInAnonymously();
  Future<void> sendEmailCode(String email);
  Future<void> verifyEmailCode(String email, String code);
  Future<void> signOut();
}

/// App setting: sign in anonymously on launch when there is no session
/// (default true; turned off by an explicit "Sign out").
const autoAnonymousSignInKey = 'ai.auto_anonymous_sign_in';

/// Signs in anonymously when the backend is configured, there is no session
/// and the user has not opted out. Never throws (offline launches simply try
/// again next time). Supabase persists the session on the device.
Future<bool> ensureAnonymousSession(
  CoachAuth auth,
  SettingsRepository settings,
) async {
  try {
    final s = auth.current;
    if (!s.configured || s.signedIn) return false;
    if ((await settings.get<bool>(autoAnonymousSignInKey)) == false) {
      return false;
    }
    await auth.signInAnonymously().timeout(const Duration(seconds: 15));
    return true;
  } catch (e) {
    debugPrint('Anonymous sign-in skipped: ${redactSecrets(e.toString())}');
    return false;
  }
}

class UnconfiguredCoachAuth implements CoachAuth {
  const UnconfiguredCoachAuth();

  static const _msg =
      'The AI backend is not configured in this build (SUPABASE_URL / '
      'SUPABASE_ANON_KEY missing).';

  @override
  CoachAuthState get current => const CoachAuthState.unconfigured();
  @override
  Stream<CoachAuthState> changes() => Stream.value(current);
  @override
  Future<void> signInAnonymously() async => throw StateError(_msg);
  @override
  Future<void> sendEmailCode(String email) async => throw StateError(_msg);
  @override
  Future<void> verifyEmailCode(String email, String code) async =>
      throw StateError(_msg);
  @override
  Future<void> signOut() async {}
}

class SupabaseCoachAuth implements CoachAuth {
  SupabaseCoachAuth(this._auth);
  final GoTrueClient _auth;

  CoachAuthState _from(User? u) => CoachAuthState(
    configured: true,
    userId: u?.id,
    email: u?.email,
    isAnonymous: u?.isAnonymous ?? false,
  );

  @override
  CoachAuthState get current => _from(_auth.currentUser);

  @override
  Stream<CoachAuthState> changes() async* {
    yield current;
    yield* _auth.onAuthStateChange.map((s) => _from(s.session?.user));
  }

  @override
  Future<void> signInAnonymously() => _guard(_auth.signInAnonymously);

  /// True while an email code was sent to link the current anonymous user.
  bool _linking = false;

  @override
  Future<void> sendEmailCode(String email) => _guard(() async {
    final e = email.trim();
    if (_auth.currentUser?.isAnonymous ?? false) {
      try {
        await _auth.updateUser(UserAttributes(email: e));
        _linking = true;
        return;
      } on AuthException catch (err) {
        // Email already registered: sign in to that account instead.
        if (err.code != 'email_exists' &&
            !err.message.toLowerCase().contains('already')) {
          rethrow;
        }
      }
    }
    _linking = false;
    await _auth.signInWithOtp(email: e);
  });

  @override
  Future<void> verifyEmailCode(String email, String code) => _guard(() async {
    await _auth.verifyOTP(
      email: email.trim(),
      token: code.trim(),
      type: _linking ? OtpType.emailChange : OtpType.email,
    );
    _linking = false;
  });

  @override
  Future<void> signOut() => _guard(_auth.signOut);

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } on AuthException catch (e) {
      throw StateError(redactSecrets(e.message));
    }
  }
}

final coachAuthProvider = Provider<CoachAuth>(
  (ref) => CoachSupabase.ready
      ? SupabaseCoachAuth(Supabase.instance.client.auth)
      : const UnconfiguredCoachAuth(),
);

final coachAuthStateProvider = StreamProvider<CoachAuthState>(
  (ref) => ref.watch(coachAuthProvider).changes(),
);
