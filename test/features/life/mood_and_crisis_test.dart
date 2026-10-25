import 'package:athlete_os/features/life/domain/crisis_detector.dart';
import 'package:athlete_os/features/life/domain/journal_text.dart';
import 'package:athlete_os/features/life/domain/mood_stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pearson / correlation thresholds', () {
    test('perfect positive and negative correlation', () {
      expect(pearson([1, 2, 3, 4], [2, 4, 6, 8]), closeTo(1, 1e-9));
      expect(pearson([1, 2, 3, 4], [8, 6, 4, 2]), closeTo(-1, 1e-9));
    });

    test('undefined with zero variance or too few points', () {
      expect(pearson([3, 3, 3], [1, 2, 3]), isNull);
      expect(pearson([1], [1]), isNull);
      expect(pearson([1, 2], [1]), isNull);
    });

    test('fewer than 7 pairs → not enough data, no r', () {
      final pairs = [for (var i = 0; i < 6; i++) (i.toDouble(), i * 2.0)];
      final r = correlate(pairs);
      expect(r.status, CorrelationStatus.notEnoughData);
      expect(r.r, isNull);
      expect(r.n, 6);
      expect(r.hasResult, isFalse);
    });

    test('7 pairs → r reported', () {
      final pairs = [for (var i = 0; i < 7; i++) (i.toDouble(), i * 2.0)];
      final r = correlate(pairs);
      expect(r.status, CorrelationStatus.ok);
      expect(r.r, closeTo(1, 1e-9));
      expect(r.strengthLabel, 'strong positive');
    });

    test('no variation → no r even with enough data', () {
      final pairs = [for (var i = 0; i < 8; i++) (i.toDouble(), 3.0)];
      expect(correlate(pairs).status, CorrelationStatus.noVariation);
    });

    test('workout vs rest days with group means', () {
      final mood = {
        for (var d = 1; d <= 8; d++)
          '2026-10-${d.toString().padLeft(2, '0')}': d.isEven ? 4.0 : 3.0,
      };
      final workouts = {'2026-10-02', '2026-10-04', '2026-10-06', '2026-10-08'};
      final r = correlateWithEventDays(mood, workouts);
      expect(r.n, 8);
      expect(r.nWith, 4);
      expect(r.nWithout, 4);
      expect(r.meanWith, 4);
      expect(r.meanWithout, 3);
      expect(r.r, closeTo(1, 1e-9));
    });

    test('daily means and pairing by day', () {
      final pts = [
        MoodPoint(
          localDate: '2026-10-01',
          recordedAt: DateTime.utc(2026, 10, 1, 8),
          mood: 2,
          sleepQuality: 3,
        ),
        MoodPoint(
          localDate: '2026-10-01',
          recordedAt: DateTime.utc(2026, 10, 1, 20),
          mood: 4,
        ),
        MoodPoint(
          localDate: '2026-10-02',
          recordedAt: DateTime.utc(2026, 10, 2, 8),
          mood: 5,
        ),
      ];
      final m = dailyMoodMeans(pts);
      expect(m['2026-10-01'], 3);
      final s = dailySleepQualityMeans(pts);
      expect(s, {'2026-10-01': 3});
      expect(pairByDay(s, m), [(3.0, 3.0)]);
      final trend = moodTrend(m, '2026-10-03', 3);
      expect(trend, [
        ('2026-10-01', 3.0),
        ('2026-10-02', 5.0),
        ('2026-10-03', null),
      ]);
    });
  });

  group('crisis detector (conservative)', () {
    test('detects clear expressions of danger', () {
      for (final t in [
        'I want to die',
        'Honestly I don’t want to be alive anymore',
        'I keep thinking about killing myself',
        'I feel suicidal tonight',
        'thinking about hurting myself again',
        'Everyone would be better off without me',
        'I want to end my life',
        'I can\'t go on anymore',
        'Urges to self-harm today',
      ]) {
        expect(detectsSevereDistress(t), isTrue, reason: t);
      }
    });

    test('does not flag gym idioms or ordinary bad days', () {
      for (final t in [
        'I killed that workout',
        'Killed it at the gym today!',
        'Suicide sprints were brutal',
        'This last set is killing me',
        'I\'m dying to try the new program',
        'Leg day nearly killed me lol',
        'I hurt myself deadlifting, tweaked my back',
        'Cut myself shaving',
        'Felt sad and tired today',
        'Rough day, stressed about work',
        '',
        null,
      ]) {
        expect(detectsSevereDistress(t), isFalse, reason: '$t');
      }
    });
  });

  test('journal export is plain text, newest first', () {
    final out = formatJournalExport(const [
      JournalExportEntry(localDate: '2026-10-01', body: 'Older'),
      JournalExportEntry(
        localDate: '2026-10-02',
        body: 'Newer',
        gratitude: 'Coffee',
        prompt: 'What went well?',
      ),
    ]);
    expect(out.indexOf('2026-10-02') < out.indexOf('2026-10-01'), isTrue);
    expect(out, contains('Grateful for: Coffee'));
    expect(out, contains('Prompt: What went well?'));
    expect(out, contains('2 entries'));
  });
}
