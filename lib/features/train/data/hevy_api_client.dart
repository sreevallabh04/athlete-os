// Client for the official Hevy public API (https://api.hevyapp.com/docs/).
// Read-only: the app never writes to Hevy. Requires Hevy Pro.
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../integrations/data/api_errors.dart';

class HevyPage<T> {
  const HevyPage({
    required this.page,
    required this.pageCount,
    required this.items,
  });
  final int page;
  final int pageCount;
  final List<T> items;
  bool get hasMore => page < pageCount;
}

/// A workout event from `/v1/workouts/events`.
sealed class HevyEvent {
  const HevyEvent();
}

class HevyUpdatedEvent extends HevyEvent {
  const HevyUpdatedEvent(this.workout);
  final Map<String, dynamic> workout;
}

class HevyDeletedEvent extends HevyEvent {
  const HevyDeletedEvent(this.id, this.deletedAt);
  final String id;
  final DateTime? deletedAt;
}

abstract interface class HevyApi {
  /// `GET /v1/user/info`. Throws [InvalidCredentialsException] for a bad key.
  Future<Map<String, dynamic>> userInfo();

  /// `GET /v1/workouts` (pageSize ≤ 10).
  Future<HevyPage<Map<String, dynamic>>> workouts({
    int page = 1,
    int pageSize = 10,
  });

  /// `GET /v1/workouts/events?since=` (pageSize ≤ 10).
  Future<HevyPage<HevyEvent>> workoutEvents({
    required DateTime since,
    int page = 1,
    int pageSize = 10,
  });

  /// `GET /v1/exercise_templates` (pageSize ≤ 100).
  Future<HevyPage<Map<String, dynamic>>> exerciseTemplates({
    int page = 1,
    int pageSize = 100,
  });
}

class HttpHevyApi implements HevyApi {
  HttpHevyApi(
    this._apiKey, {
    http.Client? client,
    this.baseUrl = 'https://api.hevyapp.com',
    this.timeout = const Duration(seconds: 20),
    this.maxAttempts = 4,
    Sleeper? sleep,
    this._random,
  }) : _client = client ?? http.Client(),
       _sleep = sleep ?? realSleep;

  final String _apiKey;
  final http.Client _client;
  final String baseUrl;
  final Duration timeout;
  final int maxAttempts;
  final Sleeper _sleep;
  final math.Random? _random;

  Future<Map<String, dynamic>?> _get(
    String path,
    Map<String, String> query, {
    bool notFoundIsEmpty = false,
  }) async {
    final uri = Uri.parse('$baseUrl$path')
        .replace(queryParameters: query.isEmpty ? null : query);
    final res = await sendWithRetry(
      () => _client.get(
        uri,
        headers: {'api-key': _apiKey, 'accept': 'application/json'},
      ),
      maxAttempts: maxAttempts,
      timeout: timeout,
      sleep: _sleep,
      random: _random,
    );
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw InvalidCredentialsException('Invalid API key');
    }
    if (res.statusCode == 404 && notFoundIsEmpty) return null;
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(
        res.statusCode,
        'Hevy request failed (HTTP ${res.statusCode}).',
      );
    }
    try {
      final body = jsonDecode(res.body);
      if (body is Map<String, dynamic>) return body;
      throw const FormatException('Unexpected JSON shape');
    } on FormatException {
      throw ApiException(res.statusCode, 'Hevy returned an invalid response.');
    }
  }

  static HevyPage<T> _page<T>(
    Map<String, dynamic>? body,
    String key,
    T? Function(Object?) map,
    int requestedPage,
  ) {
    if (body == null) {
      return HevyPage(page: requestedPage, pageCount: 0, items: const []);
    }
    final list = body[key];
    return HevyPage(
      page: (body['page'] as num?)?.toInt() ?? requestedPage,
      pageCount: (body['page_count'] as num?)?.toInt() ?? requestedPage,
      items: list is List ? list.map(map).whereType<T>().toList() : const [],
    );
  }

  @override
  Future<Map<String, dynamic>> userInfo() async =>
      (await _get('/v1/user/info', const {}))!;

  @override
  Future<HevyPage<Map<String, dynamic>>> workouts({
    int page = 1,
    int pageSize = 10,
  }) async => _page(
    await _get('/v1/workouts', {
      'page': '$page',
      'pageSize': '${pageSize.clamp(1, 10)}',
    }, notFoundIsEmpty: true),
    'workouts',
    (o) => o is Map<String, dynamic> ? o : null,
    page,
  );

  @override
  Future<HevyPage<HevyEvent>> workoutEvents({
    required DateTime since,
    int page = 1,
    int pageSize = 10,
  }) async => _page(
    await _get('/v1/workouts/events', {
      'page': '$page',
      'pageSize': '${pageSize.clamp(1, 10)}',
      'since': since.toUtc().toIso8601String(),
    }, notFoundIsEmpty: true),
    'events',
    parseHevyEvent,
    page,
  );

  @override
  Future<HevyPage<Map<String, dynamic>>> exerciseTemplates({
    int page = 1,
    int pageSize = 100,
  }) async => _page(
    await _get('/v1/exercise_templates', {
      'page': '$page',
      'pageSize': '${pageSize.clamp(1, 100)}',
    }, notFoundIsEmpty: true),
    'exercise_templates',
    (o) => o is Map<String, dynamic> ? o : null,
    page,
  );
}

HevyEvent? parseHevyEvent(Object? o) {
  if (o is! Map<String, dynamic>) return null;
  switch (o['type']) {
    case 'updated':
      final w = o['workout'];
      return w is Map<String, dynamic> ? HevyUpdatedEvent(w) : null;
    case 'deleted':
      final id = o['id'];
      if (id == null) return null;
      return HevyDeletedEvent(
        id.toString(),
        DateTime.tryParse(o['deleted_at']?.toString() ?? ''),
      );
  }
  return null;
}
