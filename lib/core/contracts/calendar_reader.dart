import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Read-only view of a calendar event, independent of the provider.
class CalendarEventView {
  const CalendarEventView({
    required this.id,
    required this.calendarId,
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.location,
    this.description,
    this.isBusy = true,
    this.htmlLink,
  });

  final String id;
  final String calendarId;
  final String title;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String? location;
  final String? description;

  /// False for events marked "free"/transparent; they don't block scheduling.
  final bool isBusy;
  final String? htmlLink;
}

/// Result wrapper so callers can distinguish "no events" from "not connected".
class CalendarReadResult {
  const CalendarReadResult.connected(this.events, {this.fetchedAt})
    : connected = true,
      error = null;
  const CalendarReadResult.notConnected()
    : connected = false,
      events = const [],
      error = null,
      fetchedAt = null;
  const CalendarReadResult.failed(this.error)
    : connected = true,
      events = const [],
      fetchedAt = null;

  final bool connected;
  final List<CalendarEventView> events;
  final String? error;
  final DateTime? fetchedAt;
}

/// Provider-agnostic calendar access used by Today, Planner, reminders and
/// the AI agent. The Google Calendar integration supplies the real
/// implementation; until it is connected this reports "not connected".
abstract interface class CalendarReader {
  Future<CalendarReadResult> eventsBetween(DateTime start, DateTime end);
}

class DisconnectedCalendarReader implements CalendarReader {
  const DisconnectedCalendarReader();
  @override
  Future<CalendarReadResult> eventsBetween(
    DateTime start,
    DateTime end,
  ) async => const CalendarReadResult.notConnected();
}

final calendarReaderProvider = Provider<CalendarReader>(
  (ref) => const DisconnectedCalendarReader(),
);
