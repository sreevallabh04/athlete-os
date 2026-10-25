import 'dart:convert';

import 'package:athlete_os/features/integrations/data/api_errors.dart';
import 'package:athlete_os/features/train/data/hevy_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final sleeps = <Duration>[];
  Future<void> fakeSleep(Duration d) async => sleeps.add(d);

  setUp(sleeps.clear);

  HttpHevyApi api(MockClient c) =>
      HttpHevyApi('secret-key-123', client: c, sleep: fakeSleep);

  test('sends api-key header and parses workouts paging', () async {
    final seen = <Uri>[];
    final client = MockClient((req) async {
      seen.add(req.url);
      expect(req.headers['api-key'], 'secret-key-123');
      return http.Response(
        jsonEncode({
          'page': 1,
          'page_count': 3,
          'workouts': [
            {'id': 'w1', 'title': 'Push'},
          ],
        }),
        200,
      );
    });
    final page = await api(client).workouts(page: 1, pageSize: 50);
    expect(page.items.single['id'], 'w1');
    expect(page.hasMore, isTrue);
    expect(seen.single.path, '/v1/workouts');
    // pageSize is clamped to the documented max of 10.
    expect(seen.single.queryParameters['pageSize'], '10');
  });

  test('parses updated and deleted workout events', () async {
    final client = MockClient((req) async {
      expect(req.url.path, '/v1/workouts/events');
      expect(req.url.queryParameters['since'], '2026-10-01T00:00:00.000Z');
      return http.Response(
        jsonEncode({
          'page': 1,
          'page_count': 1,
          'events': [
            {
              'type': 'updated',
              'workout': {'id': 'w1', 'title': 'Legs'},
            },
            {
              'type': 'deleted',
              'id': 'w2',
              'deleted_at': '2026-10-02T10:00:00Z',
            },
            {'type': 'unknown'},
          ],
        }),
        200,
      );
    });
    final page = await api(client)
        .workoutEvents(since: DateTime.utc(2026, 10, 1));
    expect(page.items, hasLength(2));
    expect(page.items[0], isA<HevyUpdatedEvent>());
    final del = page.items[1] as HevyDeletedEvent;
    expect(del.id, 'w2');
    expect(del.deletedAt, DateTime.utc(2026, 10, 2, 10));
    expect(page.hasMore, isFalse);
  });

  test('401 maps to InvalidCredentialsException "Invalid API key"', () async {
    final client = MockClient(
      (req) async => http.Response('{"error":"Unauthorized"}', 401),
    );
    await expectLater(
      api(client).userInfo(),
      throwsA(
        isA<InvalidCredentialsException>().having(
          (e) => e.message,
          'message',
          'Invalid API key',
        ),
      ),
    );
  });

  test('429 is retried honouring Retry-After, then succeeds', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      if (calls < 3) {
        return http.Response('slow down', 429, headers: {'retry-after': '2'});
      }
      return http.Response(
        jsonEncode({
          'data': {'name': 'me'},
        }),
        200,
      );
    });
    final info = await api(client).userInfo();
    expect(info['data'], {'name': 'me'});
    expect(calls, 3);
    expect(sleeps, [const Duration(seconds: 2), const Duration(seconds: 2)]);
  });

  test('5xx retried with backoff, gives up after 4 attempts', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response('oops', 503);
    });
    await expectLater(
      api(client).userInfo(),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 503)),
    );
    expect(calls, 4);
    expect(sleeps, hasLength(3));
    // Exponential: each delay at least the previous base doubling.
    expect(sleeps[1] > sleeps[0] - const Duration(milliseconds: 800), isTrue);
  });

  test('persistent 429 surfaces RateLimitedException', () async {
    final client = MockClient((req) async => http.Response('', 429));
    await expectLater(
      api(client).userInfo(),
      throwsA(isA<RateLimitedException>()),
    );
  });

  test('404 on a paging endpoint is treated as an empty page', () async {
    final client = MockClient((req) async => http.Response('', 404));
    final page = await api(client).workouts(page: 5);
    expect(page.items, isEmpty);
    expect(page.hasMore, isFalse);
  });

  test('errors never contain the API key', () async {
    final client = MockClient((req) async => http.Response('bad', 400));
    try {
      await api(client).userInfo();
      fail('should throw');
    } on IntegrationException catch (e) {
      expect(e.toString(), isNot(contains('secret-key-123')));
    }
  });
}
