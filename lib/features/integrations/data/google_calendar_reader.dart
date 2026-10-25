import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/contracts/calendar_reader.dart';
import '../../../data/repositories/integration_status_repository.dart';
import 'api_errors.dart';
import 'google_calendar_service.dart';

/// Source of calendar events for a [GoogleCalendarReader]; implemented by
/// [GoogleCalendarService] and faked in tests.
abstract interface class CalendarEventSource {
  bool get configured;
  Future<List<CalendarEventView>> eventsBetween(DateTime start, DateTime end);
}

class _ServiceSource implements CalendarEventSource {
  const _ServiceSource(this.service);
  final GoogleCalendarService service;
  @override
  bool get configured => service.configured;
  @override
  Future<List<CalendarEventView>> eventsBetween(DateTime s, DateTime e) =>
      service.eventsBetween(s, e);
}

/// [CalendarReader] backed by Google Calendar. Reports "not connected"
/// unless the integration was connected by the user; failures (e.g. expired
/// consent) are returned as [CalendarReadResult.failed], never thrown.
class GoogleCalendarReader implements CalendarReader {
  GoogleCalendarReader({
    required this._source,
    required this._status,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  factory GoogleCalendarReader.fromService(
    GoogleCalendarService service,
    IntegrationStatusRepository status,
  ) => GoogleCalendarReader(source: _ServiceSource(service), status: status);

  final CalendarEventSource _source;
  final IntegrationStatusRepository _status;
  final DateTime Function() _now;

  @override
  Future<CalendarReadResult> eventsBetween(DateTime start, DateTime end) async {
    if (!_source.configured) return const CalendarReadResult.notConnected();
    final row = await _status.get(Providers.googleCalendar);
    if (row == null ||
        row.status == ConnectionStates.disconnected ||
        row.status == ConnectionStates.needsSetup ||
        row.status == ConnectionStates.awaitingCredentials) {
      return const CalendarReadResult.notConnected();
    }
    try {
      final events = await _source.eventsBetween(start, end);
      return CalendarReadResult.connected(events, fetchedAt: _now());
    } on IntegrationException catch (e) {
      return CalendarReadResult.failed(e.message);
    } catch (_) {
      return const CalendarReadResult.failed('Could not read Google Calendar.');
    }
  }
}

/// The Google-backed reader. After merge, point the shared
/// `calendarReaderProvider` at this provider.
final googleCalendarReaderProvider = Provider<CalendarReader>(
  (ref) => GoogleCalendarReader.fromService(
    ref.watch(googleCalendarServiceProvider),
    ref.watch(integrationStatusRepositoryProvider),
  ),
);
