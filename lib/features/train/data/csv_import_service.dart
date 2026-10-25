import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/ids.dart';
import '../domain/hevy_csv_parser.dart';
import 'workout_repository.dart';

class CsvImportSummary {
  const CsvImportSummary({required this.imported, required this.warnings});
  final int imported;
  final List<String> warnings;
}

/// Imports a Hevy CSV export. Idempotent: ids are
/// `stableId('csv', title + '|' + start_time)`.
class CsvImportService {
  CsvImportService(this._workouts);
  final WorkoutRepository _workouts;

  Future<CsvImportSummary> importText(String text) async {
    final parsed = parseHevyCsv(text);
    for (final w in parsed.workouts) {
      await _workouts.upsertWorkout(
        id: stableId('csv', w.externalKey),
        source: 'csv',
        externalId: w.externalKey,
        draft: w.draft,
      );
    }
    return CsvImportSummary(
      imported: parsed.workouts.length,
      warnings: parsed.warnings,
    );
  }
}

final csvImportServiceProvider = Provider<CsvImportService>(
  (ref) => CsvImportService(ref.watch(workoutRepositoryProvider)),
);
