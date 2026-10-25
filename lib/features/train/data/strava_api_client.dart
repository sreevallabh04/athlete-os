// Client for the official Strava API v3. Only read endpoints are used.
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../integrations/data/api_errors.dart';

/// Strava rate-limit state parsed from response headers:
/// `X-RateLimit-Limit/Usage` (overall) and `X-ReadRateLimit-Limit/Usage`
/// (read), each "15-min,daily".
class StravaRateLimit {
  int? limit15;
  int? limitDay;
  int? usage15;
  int? usageDay;
  int? readLimit15;
  int? readLimitDay;
  int? readUsage15;
  int? readUsageDay;
  DateTime? observedAt;

  static (int?, int?) _pair(String? v) {
    if (v == null) return (null, null);
    final p = v.split(',').map((s) => int.tryParse(s.trim())).toList();
    return (p.isNotEmpty ? p[0] : null, p.length > 1 ? p[1] : null);
  }

  void update(Map<String, String> headers, DateTime now) {
    final l = _pair(headers['x-ratelimit-limit']);
    final u = _pair(headers['x-ratelimit-usage']);
    final rl = _pair(headers['x-readratelimit-limit']);
    final ru = _pair(headers['x-readratelimit-usage']);
    if (l.$1 == null && rl.$1 == null) return;
    limit15 = l.$1;
    limitDay = l.$2;
    usage15 = u.$1;
    usageDay = u.$2;
    readLimit15 = rl.$1;
    readLimitDay = rl.$2;
    readUsage15 = ru.$1;
    readUsageDay = ru.$2;
    observedAt = now.toUtc();
  }

  /// Start of the next 15-minute window (Strava windows align to :00, :15,
  /// :30 and :45 UTC).
  static DateTime nextWindow(DateTime now) {
    final u = now.toUtc();
    final m = (u.minute ~/ 15 + 1) * 15;
    return DateTime.utc(
      u.year,
      u.month,
      u.day,
      u.hour,
    ).add(Duration(minutes: m));
  }

  /// How long to wait before the next read request, or null if it's fine.
  /// Backs off at ≥ 90% of a 15-min limit and ≥ 95% of a daily limit.
  Duration? backoff(DateTime now) {
    final seen = observedAt;
    if (seen == null) return null;
    final u = now.toUtc();
    bool sameWindow() => nextWindow(seen) == nextWindow(u);
    bool sameDay() =>
        seen.year == u.year && seen.month == u.month && seen.day == u.day;
    bool near(int? used, int? limit, double f) =>
        used != null && limit != null && limit > 0 && used >= limit * f;
    if (sameWindow() &&
        (near(readUsage15, readLimit15, 0.9) || near(usage15, limit15, 0.9))) {
      return nextWindow(u).difference(u);
    }
    if (sameDay() &&
        (near(readUsageDay, readLimitDay, 0.95) ||
            near(usageDay, limitDay, 0.95))) {
      return DateTime.utc(u.year, u.month, u.day + 1).difference(u);
    }
    return null;
  }
}

typedef StravaTokenProvider = Future<String> Function({bool forceRefresh});

abstract interface class StravaApi {
  /// `GET /athlete/activities` (newest first is not guaranteed; per_page ≤ 200).
  Future<List<Map<String, dynamic>>> listActivities({
    DateTime? after,
    DateTime? before,
    int page = 1,
    int perPage = 100,
  });

  /// `GET /activities/{id}` (includes splits_metric and laps).
  Future<Map<String, dynamic>> activity(String id);

  /// `GET /activities/{id}/streams` — on demand only, never persisted.
  Future<Map<String, List<double>>> streams(String id);

  StravaRateLimit get rateLimit;
}

class HttpStravaApi implements StravaApi {
  HttpStravaApi({
    required this._token,
    http.Client? client,
    this.baseUrl = 'https://www.strava.com/api/v3',
    DateTime Function()? now,
    Sleeper? sleep,
  }) : _client = client ?? http.Client(),
       _now = now ?? DateTime.now,
       _sleep = sleep ?? realSleep;

  final StravaTokenProvider _token;
  final http.Client _client;
  final String baseUrl;
  final DateTime Function() _now;
  final Sleeper _sleep;

  @override
  final StravaRateLimit rateLimit = StravaRateLimit();

  Future<Object?> _get(String path, [Map<String, String>? query]) async {
    final wait = rateLimit.backoff(_now());
    if (wait != null) throw RateLimitedException(retryAfter: wait);
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    Future<http.Response> send(String token) => sendWithRetry(
      () => _client.get(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'accept': 'application/json',
        },
      ),
      maxAttempts: 3,
      sleep: _sleep,
      retryOn429: false,
    );
    var res = await send(await _token());
    rateLimit.update(res.headers, _now());
    if (res.statusCode == 401) {
      // Access tokens last 6 h; refresh once through the backend.
      res = await send(await _token(forceRefresh: true));
      rateLimit.update(res.headers, _now());
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw InvalidCredentialsException(
        'Strava authorization expired or was revoked. Reconnect Strava.',
      );
    }
    if (res.statusCode == 429) {
      throw RateLimitedException(
        retryAfter: StravaRateLimit.nextWindow(_now())
            .difference(_now().toUtc()),
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(
        res.statusCode,
        'Strava request failed (HTTP ${res.statusCode}).',
      );
    }
    try {
      return jsonDecode(res.body);
    } on FormatException {
      throw ApiException(
        res.statusCode,
        'Strava returned an invalid response.',
      );
    }
  }

  @override
  Future<List<Map<String, dynamic>>> listActivities({
    DateTime? after,
    DateTime? before,
    int page = 1,
    int perPage = 100,
  }) async {
    final body = await _get('/athlete/activities', {
      if (after != null)
        'after': '${after.toUtc().millisecondsSinceEpoch ~/ 1000}',
      if (before != null)
        'before': '${before.toUtc().millisecondsSinceEpoch ~/ 1000}',
      'page': '$page',
      'per_page': '${perPage.clamp(1, 200)}',
    });
    return body is List ? body.whereType<Map<String, dynamic>>().toList() : [];
  }

  @override
  Future<Map<String, dynamic>> activity(String id) async {
    final body = await _get('/activities/$id', {
      'include_all_efforts': 'false',
    });
    if (body is Map<String, dynamic>) return body;
    throw ApiException(200, 'Unexpected Strava activity response.');
  }

  @override
  Future<Map<String, List<double>>> streams(String id) async {
    final body = await _get('/activities/$id/streams', {
      'keys': 'time,distance,heartrate,altitude,velocity_smooth',
      'key_by_type': 'true',
    });
    return parseStravaStreams(body);
  }
}

Map<String, List<double>> parseStravaStreams(Object? body) {
  final out = <String, List<double>>{};
  void add(String type, Object? data) {
    if (data is List) {
      out[type] = [for (final v in data) (v as num?)?.toDouble() ?? double.nan];
    }
  }

  if (body is Map) {
    for (final e in body.entries) {
      final v = e.value;
      if (v is Map) add(e.key.toString(), v['data']);
    }
  } else if (body is List) {
    for (final v in body) {
      if (v is Map) add(v['type']?.toString() ?? '', v['data']);
    }
  }
  return out;
}
