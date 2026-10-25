import 'package:drift/drift.dart';

import '../../../data/db/database.dart';

/// Emits [load] once immediately and again whenever any of [tables] changes.
/// Used for views that combine several tables (habit board, auto rules).
Stream<T> watchTables<T>(
  AppDatabase db,
  List<TableInfo<Table, Object?>> tables,
  Future<T> Function() load,
) async* {
  yield await load();
  await for (final _ in db.tableUpdates(TableUpdateQuery.onAllTables(tables))) {
    yield await load();
  }
}
