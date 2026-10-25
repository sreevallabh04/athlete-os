import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart';
import '../providers.dart';

/// Well-known setting keys. Add new keys here rather than using literals.
abstract final class SettingKeys {
  static const themeMode = 'theme_mode'; // 'dark' | 'light' | 'system'
  static const onboardingDone = 'onboarding_done';

  /// Whether journal text may ever be sent to an AI provider (default false).
  static const aiJournalConsent = 'ai_journal_consent';

  /// Whether health data may be included in AI requests (default false until
  /// the user opts in on first coach use).
  static const aiHealthConsent = 'ai_health_consent';

  /// Whether meal photos may be sent to a multimodal AI provider.
  static const aiPhotoConsent = 'ai_photo_consent';
  static const calendarAwareReminders = 'calendar_aware_reminders';
  static const quietHours = 'quiet_hours'; // {"start":1320,"end":420}
  static const selectedCalendars = 'selected_calendars';
}

class SettingsRepository {
  SettingsRepository(this._db);
  final AppDatabase _db;

  Future<T?> get<T>(String key) async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    if (row == null) return null;
    return jsonDecode(row.valueJson) as T?;
  }

  Stream<T?> watch<T>(String key) =>
      (_db.select(_db.appSettings)..where((s) => s.key.equals(key)))
          .watchSingleOrNull()
          .map((r) => r == null ? null : jsonDecode(r.valueJson) as T?);

  Future<void> set(String key, Object? value) => _db
      .into(_db.appSettings)
      .insertOnConflictUpdate(
        AppSettingsCompanion.insert(
          key: key,
          valueJson: jsonEncode(value),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );
}

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(databaseProvider)),
);

final themeModeSettingProvider = StreamProvider<String>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watch<String>(SettingKeys.themeMode)
      .map((v) => v ?? 'dark'),
);
