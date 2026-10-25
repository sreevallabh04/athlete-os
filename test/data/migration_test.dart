import 'package:athlete_os/data/db/database.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  test('fresh database creates every table and seeds the profile', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final profile = await db.select(db.userProfiles).getSingle();
    expect(profile.calorieTarget, 2000);
    expect(profile.proteinTargetG, 150);
    expect(await db.select(db.replyDrafts).get(), isEmpty);
  });

  test('v1 database upgrades to v2 and gains the assistant tables', () async {
    final raw = sqlite3.openInMemory();
    // Simulate an installed v1 database: v1 tables exist, version = 1.
    final v1 = AppDatabase.forTesting(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );
    await v1.select(v1.userProfiles).get(); // triggers onCreate at v2
    for (final t in [
      'messaging_app_settings',
      'messaging_contact_rules',
      'captured_notifications',
      'reply_drafts',
      'automation_audit',
    ]) {
      raw.execute('DROP TABLE $t');
    }
    raw.execute('PRAGMA user_version = 1');
    await v1.close();

    final upgraded = AppDatabase.forTesting(NativeDatabase.opened(raw));
    addTearDown(upgraded.close);
    await upgraded.select(upgraded.automationAudit).get();
    final tables = raw
        .select("SELECT name FROM sqlite_master WHERE type='table'")
        .map((r) => r['name'] as String)
        .toSet();
    expect(
      tables,
      containsAll([
        'reply_drafts',
        'captured_notifications',
        'automation_audit',
      ]),
    );
    expect(raw.select('PRAGMA user_version').first.values.first, 2);
    // Existing data survives.
    expect((await upgraded.select(upgraded.userProfiles).get()).length, 1);
  });
}
