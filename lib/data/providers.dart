import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'db/database.dart';

/// The single app database. Overridden in tests with an in-memory instance.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
