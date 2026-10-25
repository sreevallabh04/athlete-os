import 'package:athlete_os/core/contracts/calendar_reader.dart';
import 'package:athlete_os/data/repositories/integration_status_repository.dart';
import 'package:athlete_os/features/integrations/data/api_errors.dart';
import 'package:athlete_os/features/integrations/data/google_calendar_reader.dart';
import 'package:athlete_os/features/integrations/data/google_calendar_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;

import '../../helpers/test_app.dart';

class _Source implements CalendarEventSource {
  _Source({this.configured = true, this.error});
  @override
  final bool configured;
  final IntegrationException? error;

  @override
  Future<List<CalendarEventView>> eventsBetween(DateTime s, DateTime e) async {
    if (error != null) throw error!;
    return [
      CalendarEventView(
        id: '1',
        calendarId: 'primary',
        title: 'Gym',
        start: s,
        end: s.add(const Duration(hours: 1)),
      ),
    ];
  }
}

void main() {
  test('reader is "not connected" until the user connected', () async {
    final db = newTestDb();
    addTearDown(db.close);
    final status = IntegrationStatusRepository(db);
    final s = DateTime(2026, 10, 25);
    final e = DateTime(2026, 10, 26);

    var r = await GoogleCalendarReader(
      source: _Source(),
      status: status,
    ).eventsBetween(s, e);
    expect(r.connected, isFalse);

    r = await GoogleCalendarReader(
      source: _Source(configured: false),
      status: status,
    ).eventsBetween(s, e);
    expect(r.connected, isFalse);

    await status.setStatus(
      Providers.googleCalendar,
      ConnectionStates.connected,
    );
    r = await GoogleCalendarReader(
      source: _Source(),
      status: status,
    ).eventsBetween(s, e);
    expect(r.connected, isTrue);
    expect(r.events.single.title, 'Gym');

    r = await GoogleCalendarReader(
      source: _Source(error: NeedsReconnectException()),
      status: status,
    ).eventsBetween(s, e);
    expect(r.connected, isTrue);
    expect(r.error, contains('7 days'));
  });

  test('maps Google events: timed, all-day, transparent, cancelled', () {
    final timed = mapGoogleEvent(
      gcal.Event(
        id: 'a',
        summary: 'Run club',
        start: gcal.EventDateTime(dateTime: DateTime.utc(2026, 10, 25, 1)),
        end: gcal.EventDateTime(dateTime: DateTime.utc(2026, 10, 25, 2)),
      ),
      'primary',
    )!;
    expect(timed.start.isUtc, isFalse);
    expect(timed.start.isAtSameMomentAs(DateTime.utc(2026, 10, 25, 1)), isTrue);
    expect(timed.isBusy, isTrue);

    final allDay = mapGoogleEvent(
      gcal.Event(
        id: 'b',
        start: gcal.EventDateTime(date: DateTime(2026, 10, 25)),
        end: gcal.EventDateTime(date: DateTime(2026, 10, 26)),
        transparency: 'transparent',
      ),
      'cal2',
    )!;
    expect(allDay.allDay, isTrue);
    expect(allDay.isBusy, isFalse);
    expect(allDay.title, '(No title)');
    expect(allDay.end, DateTime(2026, 10, 26));

    expect(
      mapGoogleEvent(gcal.Event(id: 'c', status: 'cancelled'), 'p'),
      isNull,
    );
  });
}
