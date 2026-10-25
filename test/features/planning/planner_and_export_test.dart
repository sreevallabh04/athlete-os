import 'dart:convert';
import 'dart:io';

import 'package:athlete_os/core/domain/free_slots.dart';
import 'package:athlete_os/core/time/clock.dart';
import 'package:athlete_os/data/db/database.dart';
import 'package:athlete_os/features/planning/data/data_export.dart';
import 'package:athlete_os/features/planning/data/photo_storage.dart';
import 'package:athlete_os/features/planning/domain/csv.dart';
import 'package:athlete_os/features/planning/domain/planner_rules.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_app.dart';

void main() {
  DateTime t(int h, [int m = 0]) => DateTime(2026, 10, 26, h, m);

  group('planner rules', () {
    test('day window from wake/sleep minutes; sleep after midnight caps', () {
      final w = dayWindow(DateTime(2026, 10, 26), 390, 1350);
      expect(w, TimeInterval(t(6, 30), t(22, 30)));
      final late = dayWindow(DateTime(2026, 10, 26), 480, 60);
      expect(late.end, DateTime(2026, 10, 27));
      expect(clipToNow(w, t(9)), TimeInterval(t(9), t(22, 30)));
      expect(clipToNow(w, t(5)), w);
    });

    test('suggested blocks are deterministic and never overlap', () {
      final free = [
        TimeInterval(t(7), t(8, 30)), // 90 min
        TimeInterval(t(12), t(12, 40)), // 40 min - too short for any block
        TimeInterval(t(18), t(20)), // 120 min
      ];
      final s = suggestBlocks(free);
      expect(s.map((b) => b.kind), [
        BlockKind.workout,
        BlockKind.focus,
        BlockKind.mealPrep,
      ]);
      expect(s[0].slot, TimeInterval(t(7), t(8)));
      expect(s[1].slot, TimeInterval(t(18), t(19)));
      expect(s[2].slot, TimeInterval(t(19), t(19, 45)));
      for (var i = 0; i < s.length; i++) {
        for (var j = i + 1; j < s.length; j++) {
          expect(s[i].slot.overlaps(s[j].slot), isFalse);
        }
      }
      expect(suggestBlocks(free), hasLength(3)); // same input, same output
      final noWorkout = suggestBlocks(free, includeWorkout: false);
      expect(noWorkout.first.kind, BlockKind.focus);
      expect(noWorkout.first.slot.start, t(7));
      expect(suggestBlocks(const []), isEmpty);
    });

    test('suggested checklist never includes unsafe cutting advice', () {
      final all = suggestedPrepChecklist.join(' ').toLowerCase();
      for (final banned in ['diuretic', 'dehydrat', 'water cut', 'sauna']) {
        expect(all.contains(banned), isFalse, reason: banned);
      }
      expect(all, contains('qualified coach'));
    });
  });

  group('csv', () {
    test('escapes quotes/commas/newlines and neutralises formulas', () {
      final csv = toCsv(
        ['a', 'b', 'c', 'd'],
        [
          ['x,y', 'say "hi"', 'line\nbreak', '=SUM(A1)'],
          [1.5, null, -3, '@cmd'],
        ],
      );
      final lines = csv.trim().split('\n');
      expect(lines.first, 'a,b,c,d');
      expect(csv, contains('"x,y","say ""hi""","line\nbreak",\'=SUM(A1)'));
      expect(csv, contains("1.5,,-3,'@cmd"));
    });
  });

  group('privacy export & delete', () {
    late AppDatabase db;
    late Directory tmp;
    late DataExportService svc;

    setUp(() async {
      db = newTestDb();
      tmp = await Directory.systemTemp.createTemp('athlete_os_test');
      svc = DataExportService(
        db,
        PhotoStorage(() async => tmp),
        FixedClock(DateTime(2026, 10, 25, 9)),
      );
      await db
          .into(db.journalEntries)
          .insert(
            JournalEntriesCompanion.insert(
              id: 'j1',
              localDate: '2026-10-25',
              body: const Value('private thoughts'),
            ),
          );
      await db
          .into(db.moodEntries)
          .insert(
            MoodEntriesCompanion.insert(
              id: 'm1',
              localDate: '2026-10-25',
              recordedAt: DateTime.utc(2026, 10, 25),
              mood: 4,
            ),
          );
      await db
          .into(db.waterLogs)
          .insert(
            WaterLogsCompanion.insert(
              id: 'w1',
              amountMl: 500,
              loggedAt: DateTime.utc(2026, 10, 25),
              localDate: '2026-10-25',
            ),
          );
      await db
          .into(db.appSettings)
          .insert(
            AppSettingsCompanion.insert(
              key: 'x',
              valueJson: jsonEncode('token=abcdef123456'),
            ),
          );
    });

    tearDown(() async {
      await db.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test(
      'JSON export includes user tables, excludes sync queue, redacts secrets',
      () async {
        final json =
            jsonDecode(await svc.exportAllJson()) as Map<String, dynamic>;
        final tables = json['tables'] as Map<String, dynamic>;
        expect(tables.keys, contains('journal_entries'));
        expect(tables.keys, contains('user_profiles'));
        expect(tables.keys, isNot(contains('sync_queue')));
        expect((tables['water_logs'] as List).single['amountMl'], 500);
        expect(
          jsonEncode(tables['app_settings']),
          isNot(contains('abcdef123456')),
        );
      },
    );

    test(
      'CSV export: journal only on request; datasets are separate',
      () async {
        final water = await svc.exportCsv(
          ExportDataset.water,
          '2026-10-01',
          '2026-10-31',
        );
        expect(water, startsWith('date,logged_at_utc,amount_ml,source'));
        expect(water, contains('2026-10-25'));
        expect(water, isNot(contains('private thoughts')));
        final journal = await svc.exportCsv(
          ExportDataset.journal,
          '2026-10-01',
          '2026-10-31',
        );
        expect(journal, contains('private thoughts'));
      },
    );

    test(
      'delete categories remove only their data; photos delete files',
      () async {
        final photoDir = await PhotoStorage(() async => tmp).directory();
        final file = File('${photoDir.path}${Platform.pathSeparator}p1.jpg')
          ..writeAsBytesSync([1, 2, 3]);
        await db
            .into(db.progressPhotos)
            .insert(
              ProgressPhotosCompanion.insert(
                id: 'p1',
                localPath: file.path,
                takenAt: DateTime.utc(2026, 10, 25),
                localDate: '2026-10-25',
              ),
            );

        await svc.deleteCategory(DeleteCategory.journal);
        expect(await db.select(db.journalEntries).get(), isEmpty);
        expect(await db.select(db.moodEntries).get(), hasLength(1));

        await svc.deleteCategory(DeleteCategory.progressPhotos);
        expect(await db.select(db.progressPhotos).get(), isEmpty);
        expect(file.existsSync(), isFalse);

        await svc.deleteCategory(DeleteCategory.everything);
        expect(await db.select(db.moodEntries).get(), isEmpty);
        expect(await db.select(db.waterLogs).get(), isEmpty);
        final profile = await db.select(db.userProfiles).getSingle();
        expect(profile.calorieTarget, 2000); // reset to example defaults
      },
    );
  });
}
