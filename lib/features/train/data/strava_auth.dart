// Strava OAuth: authorization in a Custom Tab (flutter_web_auth_2), code
// exchange/refresh/revoke on the `strava-oauth` Supabase Edge Function so
// the client secret and refresh token never live on the device.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/env.dart';
import '../../../core/time/clock.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../integrations/data/api_errors.dart';
import '../../integrations/data/secret_store.dart';

const kStravaRedirectUri = 'athleteos://localhost/strava';
const kStravaCallbackScheme = 'athleteos';
const kStravaScopes = 'read,activity:read_all';

class StravaTokenGrant {
  const StravaTokenGrant({
    required this.accessToken,
    required this.expiresAt,
    this.athleteId,
    this.scope,
  });
  final String accessToken;
  final DateTime expiresAt;
  final int? athleteId;
  final String? scope;

  static StravaTokenGrant fromJson(Object? data) {
    if (data is! Map) {
      throw ApiException(502, 'Unexpected response from the Strava backend.');
    }
    final token = data['access_token'];
    final exp = data['expires_at'];
    if (token is! String || token.isEmpty || exp is! num) {
      throw ApiException(502, 'Unexpected response from the Strava backend.');
    }
    return StravaTokenGrant(
      accessToken: token,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        exp.toInt() * 1000,
        isUtc: true,
      ),
      athleteId: (data['athlete_id'] as num?)?.toInt(),
      scope: data['scope']?.toString(),
    );
  }
}

/// Server-side token operations (Supabase Edge Function `strava-oauth`).
abstract interface class StravaBackend {
  Future<StravaTokenGrant> exchange({
    required String code,
    required String redirectUri,
    String? scope,
  });
  Future<StravaTokenGrant> refresh();
  Future<void> revoke();
}

class SupabaseStravaBackend implements StravaBackend {
  const SupabaseStravaBackend();

  SupabaseClient _client() {
    if (!Env.hasSupabase) {
      throw AwaitingCredentialsException(
        'Backend not configured (SUPABASE_URL / SUPABASE_ANON_KEY).',
      );
    }
    final SupabaseClient client;
    try {
      client = Supabase.instance.client;
    } catch (_) {
      throw AwaitingCredentialsException('Backend is not initialised yet.');
    }
    if (client.auth.currentSession == null) {
      throw AwaitingCredentialsException(
        'Sign in to the Athlete OS backend first — the Strava token service '
        'requires a signed-in user.',
      );
    }
    return client;
  }

  Future<Object?> _invoke(Map<String, Object?> body) async {
    final client = _client();
    try {
      final res = await client.functions.invoke('strava-oauth', body: body);
      return res.data;
    } on FunctionException catch (e) {
      final details = e.details;
      final code = details is Map ? details['error']?.toString() : null;
      if (e.status == 401 && code == 'reauthorize_required') {
        throw InvalidCredentialsException(
          'Strava access was revoked. Reconnect Strava.',
        );
      }
      if (e.status == 401) {
        throw AwaitingCredentialsException('Backend sign-in expired.');
      }
      if (e.status == 404 && code == 'not_connected') {
        throw InvalidCredentialsException('Strava is not connected.');
      }
      if (e.status == 429) throw RateLimitedException();
      if (e.status == 500 && code == 'server_not_configured') {
        throw AwaitingCredentialsException(
          'Strava secrets are not set on the backend.',
        );
      }
      throw ApiException(
        e.status,
        'Strava backend error (${code ?? 'HTTP ${e.status}'}).',
      );
    } on IntegrationException {
      rethrow;
    } catch (e) {
      throw NetworkException('Could not reach the Strava backend.');
    }
  }

  @override
  Future<StravaTokenGrant> exchange({
    required String code,
    required String redirectUri,
    String? scope,
  }) async => StravaTokenGrant.fromJson(
    await _invoke({
      'action': 'exchange',
      'code': code,
      'redirect_uri': redirectUri,
      'scope': ?scope,
    }),
  );

  @override
  Future<StravaTokenGrant> refresh() async =>
      StravaTokenGrant.fromJson(await _invoke({'action': 'refresh'}));

  @override
  Future<void> revoke() async {
    await _invoke({'action': 'revoke'});
  }
}

typedef WebAuthLauncher = Future<String> Function({
  required String url,
  required String callbackUrlScheme,
});

Future<String> _defaultLauncher({
  required String url,
  required String callbackUrlScheme,
}) => FlutterWebAuth2.authenticate(
  url: url,
  callbackUrlScheme: callbackUrlScheme,
);

class StravaAuthService {
  StravaAuthService({
    required this._secrets,
    required this._backend,
    required this._status,
    required this._clock,
    WebAuthLauncher? launcher,
    math.Random? random,
    bool? configured,
    String? clientId,
  }) : _launcher = launcher ?? _defaultLauncher,
       _random = random ?? math.Random.secure(),
       _configured = configured ?? Env.hasStrava,
       _clientId = clientId ?? Env.stravaClientId;

  final SecretStore _secrets;
  final StravaBackend _backend;
  final IntegrationStatusRepository _status;
  final Clock _clock;
  final WebAuthLauncher _launcher;
  final math.Random _random;
  final bool _configured;
  final String _clientId;

  bool get configured => _configured;

  Uri authorizeUri(String state) =>
      Uri.https('www.strava.com', '/oauth/mobile/authorize', {
        'client_id': _clientId,
        'redirect_uri': kStravaRedirectUri,
        'response_type': 'code',
        'approval_prompt': 'auto',
        'scope': kStravaScopes,
        'state': state,
      });

  String _newState() => List.generate(
    24,
    (_) => _random.nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Runs the full OAuth flow. Marks Strava connected only after the
  /// backend exchange succeeded.
  Future<void> connect() async {
    if (!_configured) {
      throw AwaitingCredentialsException(
        'Strava client ID and backend are not configured for this build.',
      );
    }
    final state = _newState();
    final String result;
    try {
      result = await _launcher(
        url: authorizeUri(state).toString(),
        callbackUrlScheme: kStravaCallbackScheme,
      );
    } catch (e) {
      throw ApiException(0, 'Strava sign-in was cancelled.');
    }
    final uri = Uri.parse(result);
    final q = uri.queryParameters;
    if (q['state'] != state) {
      throw ApiException(0, 'Strava sign-in failed (state mismatch).');
    }
    if (q['error'] != null) {
      throw ApiException(
        0,
        q['error'] == 'access_denied'
            ? 'Strava access was denied.'
            : 'Strava sign-in failed (${q['error']}).',
      );
    }
    final code = q['code'];
    if (code == null || code.isEmpty) {
      throw ApiException(0, 'Strava did not return an authorization code.');
    }
    final granted = q['scope'] ?? '';
    if (!granted.contains('activity:read')) {
      throw ApiException(
        0,
        'Activity access was not granted. Please allow "View data about your '
        'activities" to sync runs.',
      );
    }
    try {
      final grant = await _backend.exchange(
        code: code,
        redirectUri: kStravaRedirectUri,
        scope: granted,
      );
      await _store(grant);
      await _status.setStatus(
        'strava',
        ConnectionStates.connected,
        scopes: (grant.scope ?? granted)
            .split(',')
            .where((s) => s.isNotEmpty)
            .toList(),
        meta: {if (grant.athleteId != null) 'athlete_id': grant.athleteId},
      );
    } on IntegrationException catch (e) {
      await _status.setStatus(
        'strava',
        ConnectionStates.error,
        error: e.message,
      );
      rethrow;
    }
  }

  Future<void> _store(StravaTokenGrant g) async {
    await _secrets.write(SecretKeys.stravaAccessToken, g.accessToken);
    await _secrets.write(
      SecretKeys.stravaExpiresAt,
      '${g.expiresAt.millisecondsSinceEpoch ~/ 1000}',
    );
  }

  /// A valid access token, refreshed through the backend when it expires
  /// within 5 minutes (or when [forceRefresh]).
  Future<String> accessToken({bool forceRefresh = false}) async {
    final token = await _secrets.read(SecretKeys.stravaAccessToken);
    final exp = int.tryParse(
      await _secrets.read(SecretKeys.stravaExpiresAt) ?? '',
    );
    final now = _clock.now().toUtc();
    final valid =
        token != null &&
        exp != null &&
        DateTime.fromMillisecondsSinceEpoch(
          exp * 1000,
          isUtc: true,
        ).isAfter(now.add(const Duration(minutes: 5)));
    if (valid && !forceRefresh) return token;
    final grant = await _backend.refresh();
    await _store(grant);
    return grant.accessToken;
  }

  Future<bool> hasToken() async =>
      (await _secrets.read(SecretKeys.stravaAccessToken)) != null;

  /// Best-effort server revoke, then local token removal.
  Future<void> revokeAndClear() async {
    try {
      await _backend.revoke();
    } on IntegrationException {
      // Local data is still removed; the user can revoke in Strava settings.
    }
    await _secrets.delete(SecretKeys.stravaAccessToken);
    await _secrets.delete(SecretKeys.stravaExpiresAt);
  }
}

final stravaBackendProvider = Provider<StravaBackend>(
  (ref) => const SupabaseStravaBackend(),
);

final stravaAuthServiceProvider = Provider<StravaAuthService>(
  (ref) => StravaAuthService(
    secrets: ref.watch(secretStoreProvider),
    backend: ref.watch(stravaBackendProvider),
    status: ref.watch(integrationStatusRepositoryProvider),
    clock: ref.watch(clockProvider),
  ),
);
