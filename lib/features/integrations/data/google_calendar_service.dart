// Google Calendar via google_sign_in 7.x + googleapis.
//
// * Read-only scope is requested when the user taps Connect.
// * `calendar.events` is requested incrementally ONLY when the user creates an
//   event after an explicit confirmation dialog.
// * OAuth apps in "Testing" mode lose consent after 7 days; that surfaces as a
//   failed silent authorization → status error "needs reconnect".
import 'dart:async';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;

import '../../../core/config/env.dart';
import '../../../core/contracts/calendar_reader.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/ids.dart';
import '../../../data/db/database.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../../data/repositories/settings_repository.dart';
import 'api_errors.dart';

const kCalendarReadScope = 'https://www.googleapis.com/auth/calendar.readonly';
const kCalendarEventsScope = 'https://www.googleapis.com/auth/calendar.events';

const kNeedsReconnectMessage =
    'Google consent expired or was revoked. Test-mode OAuth apps require '
    're-consent every 7 days — tap Reconnect.';

class CalendarInfo {
  const CalendarInfo({
    required this.id,
    required this.name,
    this.primary = false,
    this.color,
    this.canWrite = false,
  });
  final String id;
  final String name;
  final bool primary;
  final String? color;
  final bool canWrite;
}

class NeedsReconnectException extends InvalidCredentialsException {
  NeedsReconnectException() : super(kNeedsReconnectMessage);
}

class CancelledException extends ApiException {
  CancelledException() : super(0, 'Cancelled');
}

class GoogleCalendarService {
  GoogleCalendarService({
    required this._db,
    required this._status,
    required this._settings,
    required this._clock,
  });

  final AppDatabase _db;
  final IntegrationStatusRepository _status;
  final SettingsRepository _settings;
  final Clock _clock;

  GoogleSignInAccount? _account;
  Future<void>? _init;

  bool get configured => Env.hasGoogle;
  String? get email => _account?.email;

  Future<void> _ensureInitialized() {
    if (!configured) {
      throw AwaitingCredentialsException(
        'GOOGLE_WEB_CLIENT_ID is not configured for this build.',
      );
    }
    return _init ??= GoogleSignIn.instance.initialize(
      serverClientId: Env.googleWebClientId,
    );
  }

  /// Silent restore on app start. Never prompts; never throws.
  Future<bool> restore() async {
    if (!configured) return false;
    try {
      await _ensureInitialized();
      final row = await _status.get(Providers.googleCalendar);
      if (row == null || row.status == ConnectionStates.disconnected) {
        return false;
      }
      _account ??= await GoogleSignIn.instance
          .attemptLightweightAuthentication();
      if (_account == null) {
        await _markNeedsReconnect();
        return false;
      }
      final authz = await _account!.authorizationClient.authorizationForScopes(
        const [kCalendarReadScope],
      );
      if (authz == null) {
        await _markNeedsReconnect();
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _markNeedsReconnect() => _status.setStatus(
    Providers.googleCalendar,
    ConnectionStates.error,
    error: kNeedsReconnectMessage,
  );

  /// User-initiated: sign in, grant read-only access, verify with a real
  /// calendar list call, then mark connected.
  Future<void> connect() async {
    await _ensureInitialized();
    try {
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: const [kCalendarReadScope],
      );
      _account = account;
      await account.authorizationClient.authorizeScopes(const [
        kCalendarReadScope,
      ]);
      final cals = await listCalendars();
      final selected = await _settings.get<List<dynamic>>(
        SettingKeys.selectedCalendars,
      );
      if (selected == null || selected.isEmpty) {
        final primary = cals.where((c) => c.primary).map((c) => c.id).toList();
        await _settings.set(
          SettingKeys.selectedCalendars,
          primary.isEmpty ? ['primary'] : primary,
        );
      }
      final existing = await _status.get(Providers.googleCalendar);
      final hadWrite =
          existing?.scopesJson.contains(kCalendarEventsScope) ?? false;
      await _status.setStatus(
        Providers.googleCalendar,
        ConnectionStates.connected,
        scopes: [kCalendarReadScope, if (hadWrite) kCalendarEventsScope],
        meta: {'email': account.email},
      );
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw CancelledException();
      }
      final msg = e.code == GoogleSignInExceptionCode.clientConfigurationError
          ? 'Google sign-in is misconfigured (check SHA-1, package name and '
                'the Web client ID).'
          : 'Google sign-in failed (${e.code.name}).';
      await _status.setStatus(
        Providers.googleCalendar,
        ConnectionStates.error,
        error: msg,
      );
      throw ApiException(0, msg);
    } on IntegrationException catch (e) {
      await _status.setStatus(
        Providers.googleCalendar,
        ConnectionStates.error,
        error: e.message,
      );
      rethrow;
    }
  }

  Future<void> disconnect() async {
    try {
      await _ensureInitialized();
      await GoogleSignIn.instance.disconnect();
    } catch (_) {
      // Still mark disconnected locally.
    }
    _account = null;
    await _status.setStatus(
      Providers.googleCalendar,
      ConnectionStates.disconnected,
      scopes: const [],
      clearError: true,
    );
  }

  Future<gcal.CalendarApi> _api(String scope, {bool prompt = false}) async {
    await _ensureInitialized();
    _account ??= await GoogleSignIn.instance.attemptLightweightAuthentication();
    final account = _account;
    if (account == null) throw NeedsReconnectException();
    GoogleSignInClientAuthorization? authz;
    try {
      authz = prompt
          ? await account.authorizationClient.authorizeScopes([scope])
          : await account.authorizationClient.authorizationForScopes([scope]);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw CancelledException();
      }
      rethrow;
    }
    if (authz == null) {
      await _markNeedsReconnect();
      throw NeedsReconnectException();
    }
    return gcal.CalendarApi(authz.authClient(scopes: [scope]));
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on gcal.DetailedApiRequestError catch (e) {
      if (e.status == 401) {
        await _markNeedsReconnect();
        throw NeedsReconnectException();
      }
      if (e.status == 403) {
        throw ApiException(
          403,
          'Google Calendar refused the request (API not enabled or '
          'permission missing).',
        );
      }
      if (e.status == 429) throw RateLimitedException();
      throw ApiException(e.status ?? 0, 'Google Calendar error: ${e.message}');
    } on IntegrationException {
      rethrow;
    } on TimeoutException {
      throw NetworkException();
    }
  }

  Future<List<CalendarInfo>> listCalendars() => _guard(() async {
    final api = await _api(kCalendarReadScope);
    final out = <CalendarInfo>[];
    String? page;
    do {
      final res = await api.calendarList.list(pageToken: page);
      for (final c in res.items ?? const <gcal.CalendarListEntry>[]) {
        if (c.id == null) continue;
        out.add(
          CalendarInfo(
            id: c.id!,
            name: c.summaryOverride ?? c.summary ?? c.id!,
            primary: c.primary ?? false,
            color: c.backgroundColor,
            canWrite: c.accessRole == 'owner' || c.accessRole == 'writer',
          ),
        );
      }
      page = res.nextPageToken;
    } while (page != null);
    return out;
  });

  Future<List<String>> selectedCalendarIds() async {
    final v = await _settings.get<List<dynamic>>(SettingKeys.selectedCalendars);
    final ids = (v ?? const []).map((e) => e.toString()).toList();
    return ids.isEmpty ? ['primary'] : ids;
  }

  Future<void> setSelectedCalendars(List<String> ids) =>
      _settings.set(SettingKeys.selectedCalendars, ids);

  /// Events in [start, end) across the selected calendars, times in local tz.
  Future<List<CalendarEventView>> eventsBetween(DateTime start, DateTime end) =>
      _guard(() async {
        final api = await _api(kCalendarReadScope);
        final out = <CalendarEventView>[];
        for (final calId in await selectedCalendarIds()) {
          String? page;
          do {
            final res = await api.events.list(
              calId,
              timeMin: start.toUtc(),
              timeMax: end.toUtc(),
              singleEvents: true,
              orderBy: 'startTime',
              maxResults: 250,
              pageToken: page,
            );
            for (final e in res.items ?? const <gcal.Event>[]) {
              final v = mapGoogleEvent(e, calId);
              if (v != null) out.add(v);
            }
            page = res.nextPageToken;
          } while (page != null);
        }
        out.sort((a, b) => a.start.compareTo(b.start));
        return out;
      });

  /// Creates an event. Must only be called after the user confirmed it.
  /// Requests the `calendar.events` scope incrementally (user-initiated).
  Future<String> createEvent({
    required String kind,
    required String title,
    required DateTime start,
    required DateTime end,
    String calendarId = 'primary',
    String? description,
  }) => _guard(() async {
    final api = await _api(kCalendarEventsScope, prompt: true);
    final event = gcal.Event(
      summary: title,
      description:
          description ?? 'Planned with Athlete OS ($kind). Edit freely.',
      start: gcal.EventDateTime(dateTime: start.toUtc()),
      end: gcal.EventDateTime(dateTime: end.toUtc()),
    );
    final created = await api.events.insert(event, calendarId);
    final eventId = created.id ?? '';
    await _db
        .into(_db.calendarEventRefs)
        .insert(
          CalendarEventRefsCompanion.insert(
            id: newId(),
            calendarId: calendarId,
            eventId: eventId,
            kind: kind,
            startAt: start.toUtc(),
            endAt: end.toUtc(),
          ),
        );
    await _status.setStatus(
      Providers.googleCalendar,
      ConnectionStates.connected,
      scopes: const [kCalendarReadScope, kCalendarEventsScope],
    );
    return eventId;
  });

  DateTime now() => _clock.now();
}

/// Maps a Google event to the provider-agnostic view (null for cancelled).
CalendarEventView? mapGoogleEvent(gcal.Event e, String calendarId) {
  if (e.status == 'cancelled' || e.id == null) return null;
  final allDay = e.start?.date != null;
  DateTime? s;
  DateTime? en;
  if (allDay) {
    final sd = e.start!.date!;
    final ed = e.end?.date ?? sd.add(const Duration(days: 1));
    s = DateTime(sd.year, sd.month, sd.day);
    en = DateTime(ed.year, ed.month, ed.day);
  } else {
    s = e.start?.dateTime?.toLocal();
    en = e.end?.dateTime?.toLocal();
  }
  if (s == null) return null;
  return CalendarEventView(
    id: e.id!,
    calendarId: calendarId,
    title: e.summary ?? '(No title)',
    start: s,
    end: en ?? s.add(const Duration(hours: 1)),
    allDay: allDay,
    location: e.location,
    description: e.description,
    isBusy: e.transparency != 'transparent',
    htmlLink: e.htmlLink,
  );
}

final googleCalendarServiceProvider = Provider<GoogleCalendarService>(
  (ref) => GoogleCalendarService(
    db: ref.watch(databaseProvider),
    status: ref.watch(integrationStatusRepositoryProvider),
    settings: ref.watch(settingsRepositoryProvider),
    clock: ref.watch(clockProvider),
  ),
);
