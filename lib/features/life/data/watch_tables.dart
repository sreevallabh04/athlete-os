import 'dart:async';

import 'package:drift/drift.dart';

import '../../../data/db/database.dart';

/// Emits [load] once immediately and again whenever any of [tables] changes.
/// Used for views that combine several tables (habit board, auto rules,
/// planned sessions).
///
/// The change subscription starts *before* the first load: writes that land
/// while it runs (e.g. calibration finishing just as a tab opens) are
/// buffered and trigger a reload instead of being lost.
Stream<T> watchTables<T>(
  AppDatabase db,
  List<TableInfo<Table, Object?>> tables,
  Future<T> Function() load,
) async* {
  final changes = StreamController<void>();
  final sub = db
      .tableUpdates(TableUpdateQuery.onAllTables(tables))
      .listen((_) => changes.add(null));
  try {
    yield await load();
    await for (final _ in changes.stream) {
      yield await load();
    }
  } finally {
    await sub.cancel();
    await changes.close();
  }
}
