import 'package:flutter_riverpod/misc.dart' show Override;

import '../core/contracts/calendar_reader.dart';
import '../features/integrations/data/google_calendar_reader.dart';

/// Binds shared contracts (declared in `core/`) to their feature
/// implementations. Keeping this wiring in `app/` means `core/` never
/// depends on a feature, and tests can still override each contract.
List<Override> appOverrides() => [
  calendarReaderProvider.overrideWith(
    (ref) => ref.watch(googleCalendarReaderProvider),
  ),
];
