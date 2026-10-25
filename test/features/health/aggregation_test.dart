import 'package:athlete_os/features/health/domain/aggregation.dart';
import 'package:athlete_os/features/health/domain/health_types.dart';
import 'package:athlete_os/features/health/domain/sources.dart';
import 'package:flutter_test/flutter_test.dart';

HcRecord rec(
  HcDataType type,
  DateTime start,
  DateTime end, {
  double value = 0,
  String uuid = '',
  String source = samsungHealthPackage,
  String? workoutType,
}) => HcRecord(
  uuid: uuid,
  type: type,
  value: value,
  unit: 'X',
  start: start,
  end: end,
  sourceApp: source,
  workoutType: workoutType,
);

void main() {
  group('sleep night assignment', () {
    test('a session crossing midnight belongs to the date it ends', () {
      final s = rec(
        HcDataType.sleepSession,
        DateTime(2026, 10, 24, 23, 30),
        DateTime(2026, 10, 25, 7),
        uuid: 's1',
      );
      expect(sleepNightDate(s.end), '2026-10-25');
      final nights = sleepMinutesPerNight([s]);
      expect(nights.keys, ['2026-10-25']);
      expect(nights['2026-10-25']!.value, 450);
    });

    test('a nap and a night ending the same day add up; overlap merged', () {
      final night = rec(
        HcDataType.sleepSession,
        DateTime(2026, 10, 24, 23),
        DateTime(2026, 10, 25, 6),
        uuid: 'a',
      );
      final overlapDup = rec(
        HcDataType.sleepSession,
        DateTime(2026, 10, 25, 5),
        DateTime(2026, 10, 25, 7),
        uuid: 'b',
      );
      final nap = rec(
        HcDataType.sleepSession,
        DateTime(2026, 10, 25, 14),
        DateTime(2026, 10, 25, 14, 30),
        uuid: 'c',
      );
      final n = sleepMinutesPerNight([night, overlapDup, nap]);
      expect(n['2026-10-25']!.value, 8 * 60 + 30);
    });

    test('one source per night: the source with the most sleep wins', () {
      final samsung = rec(
        HcDataType.sleepSession,
        DateTime(2026, 10, 24, 23),
        DateTime(2026, 10, 25, 7),
        uuid: 's',
      );
      final other = rec(
        HcDataType.sleepSession,
        DateTime(2026, 10, 24, 23, 30),
        DateTime(2026, 10, 25, 6, 30),
        uuid: 'o',
        source: 'com.example.sleep',
      );
      final n = sleepMinutesPerNight([samsung, other])['2026-10-25']!;
      expect(n.value, 480);
      expect(n.primarySource, samsungHealthPackage);
      expect(n.otherSources, ['com.example.sleep']);
      expect(n.sourcesSummary, contains('Samsung Health'));
    });
  });

  group('active minutes (exercise overlap merge)', () {
    test('overlapping phone + watch sessions are counted once', () {
      final watch = rec(
        HcDataType.exercise,
        DateTime(2026, 10, 25, 7),
        DateTime(2026, 10, 25, 7, 40),
        uuid: 'w',
      );
      final phone = rec(
        HcDataType.exercise,
        DateTime(2026, 10, 25, 7, 10),
        DateTime(2026, 10, 25, 7, 50),
        uuid: 'p',
        source: googleFitPackage,
      );
      final later = rec(
        HcDataType.exercise,
        DateTime(2026, 10, 25, 18),
        DateTime(2026, 10, 25, 18, 30),
        uuid: 'l',
      );
      expect(activeMinutesPerDay([watch, phone, later]), {'2026-10-25': 80});
    });

    test('duplicate uuids are ignored', () {
      final a = rec(
        HcDataType.exercise,
        DateTime(2026, 10, 25, 7),
        DateTime(2026, 10, 25, 8),
        uuid: 'x',
      );
      expect(activeMinutesPerDay([a, a]), {'2026-10-25': 60});
    });

    test('a session crossing midnight is split per local day', () {
      final s = rec(
        HcDataType.exercise,
        DateTime(2026, 10, 24, 23, 30),
        DateTime(2026, 10, 25, 0, 45),
        uuid: 'm',
      );
      expect(activeMinutesPerDay([s]), {'2026-10-24': 30, '2026-10-25': 45});
    });

    test('mergeIntervals merges adjacent and nested intervals', () {
      final m = mergeIntervals([
        TimeInterval(DateTime(2026, 1, 1, 10), DateTime(2026, 1, 1, 11)),
        TimeInterval(
          DateTime(2026, 1, 1, 10, 15),
          DateTime(2026, 1, 1, 10, 30),
        ),
        TimeInterval(DateTime(2026, 1, 1, 11), DateTime(2026, 1, 1, 12)),
        TimeInterval(DateTime(2026, 1, 1, 13), DateTime(2026, 1, 1, 13)),
      ]);
      expect(m, [
        TimeInterval(DateTime(2026, 1, 1, 10), DateTime(2026, 1, 1, 12)),
      ]);
    });
  });

  group('daily totals (distance / calories)', () {
    test('overlapping records within one source are pro-rated', () {
      final a = rec(
        HcDataType.distance,
        DateTime(2026, 10, 25, 8),
        DateTime(2026, 10, 25, 8, 10),
        value: 1000,
        uuid: 'a',
      );
      // Half overlaps a.
      final b = rec(
        HcDataType.distance,
        DateTime(2026, 10, 25, 8, 5),
        DateTime(2026, 10, 25, 8, 15),
        value: 1000,
        uuid: 'b',
      );
      expect(proratedSum([a, b]), closeTo(1500, 1e-6));
    });

    test('only the largest source per day is counted', () {
      final samsung = rec(
        HcDataType.distance,
        DateTime(2026, 10, 25, 8),
        DateTime(2026, 10, 25, 9),
        value: 5000,
        uuid: 's',
      );
      final fit = rec(
        HcDataType.distance,
        DateTime(2026, 10, 25, 8),
        DateTime(2026, 10, 25, 9),
        value: 4800,
        uuid: 'f',
        source: googleFitPackage,
      );
      final t = dailyTotalsSingleSource([samsung, fit])['2026-10-25']!;
      expect(t.value, 5000);
      expect(t.otherSources, [googleFitPackage]);
      expect(t.sourcesSummary, contains('Google Fit'));
    });
  });

  group('heart-rate downsampling', () {
    test('keeps at most one actual reading per 5 minutes', () {
      final base = DateTime.utc(2026, 10, 25, 10);
      final samples = [
        for (var i = 0; i < 30; i++)
          rec(
            HcDataType.heartRate,
            base.add(Duration(minutes: i)),
            base.add(Duration(minutes: i)),
            value: 60.0 + i,
            uuid: 'series',
          ),
      ];
      final kept = downsampleHeartRate(samples);
      expect(kept, hasLength(6));
      expect(kept.first.sample.value, 64); // latest in first bucket
      expect(kept.first.count, 5);
      expect(kept.first.min, 60);
      expect(kept.first.max, 64);
    });
  });

  group('labels', () {
    test('source app mapping', () {
      expect(sourceAppLabel('com.sec.android.app.shealth'), 'Samsung Health');
      expect(sourceAppLabel('com.google.android.apps.fitness'), 'Google Fit');
      expect(sourceAppLabel('com.example.app'), 'com.example.app');
      expect(sourceAppLabel(null), 'Unknown app');
    });

    test('device type from metadata, unknown otherwise', () {
      expect(deviceTypeFromMetadata(null), 'unknown');
      expect(deviceTypeFromMetadata({'device_type': 'WATCH'}), 'watch');
      expect(deviceTypeFromMetadata({'deviceType': 2}), 'phone');
    });

    test('cardio sport normalisation', () {
      expect(normaliseCardioSport('RUNNING_TREADMILL'), 'run');
      expect(normaliseCardioSport('WALKING'), 'walk');
      expect(normaliseCardioSport('HIKING'), 'hike');
      expect(normaliseCardioSport('BIKING_STATIONARY'), 'ride');
      expect(normaliseCardioSport('STRENGTH_TRAINING'), isNull);
      expect(normaliseCardioSport(null), isNull);
    });
  });
}
