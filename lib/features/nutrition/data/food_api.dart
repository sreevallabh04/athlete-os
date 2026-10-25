import 'dart:async';
import 'dart:io' show SocketException;
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../../core/util/redact.dart';
import '../domain/rate_limiter.dart';

enum FoodApiErrorKind {
  offline,
  timeout,
  rateLimited,
  server,
  badResponse,
  notConfigured,
}

/// User-presentable, already-redacted API error.
class FoodApiException implements Exception {
  FoodApiException(this.kind, String message, {this.retryAfter})
    : message = redactSecrets(message);

  final FoodApiErrorKind kind;
  final String message;
  final Duration? retryAfter;

  @override
  String toString() => message;
}

/// Shared GET with timeout, client-side rate limit and retry/backoff for
/// 429/5xx and transient network failures.
class ResilientGetter {
  ResilientGetter({
    required this.client,
    required this.serviceName,
    this.timeout = const Duration(seconds: 12),
    this.maxRetries = 2,
    this.baseBackoff = const Duration(milliseconds: 600),
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? Future<void>.delayed;

  final http.Client client;
  final String serviceName;
  final Duration timeout;
  final int maxRetries;
  final Duration baseBackoff;
  final Future<void> Function(Duration) _sleep;

  /// Returns the response for 2xx and 404 (callers decide what 404 means).
  Future<http.Response> get(
    Uri uri, {
    required Map<String, String> headers,
    RateLimiter? limiter,
  }) async {
    var attempt = 0;
    while (true) {
      final wait = limiter?.tryAcquire();
      if (wait != null) {
        throw FoodApiException(
          FoodApiErrorKind.rateLimited,
          'Too many $serviceName requests. Try again in '
          '${math.max(1, wait.inSeconds)} s.',
          retryAfter: wait,
        );
      }
      http.Response res;
      try {
        res = await client.get(uri, headers: headers).timeout(timeout);
      } on TimeoutException {
        if (attempt < maxRetries) {
          await _sleep(_backoff(attempt++));
          continue;
        }
        throw FoodApiException(
          FoodApiErrorKind.timeout,
          '$serviceName did not respond in time. Check your connection and '
          'try again.',
        );
      } on SocketException {
        throw FoodApiException(
          FoodApiErrorKind.offline,
          "You're offline or $serviceName is unreachable. Local foods still "
          'work.',
        );
      } on http.ClientException {
        throw FoodApiException(
          FoodApiErrorKind.offline,
          "You're offline or $serviceName is unreachable. Local foods still "
          'work.',
        );
      }
      final code = res.statusCode;
      if ((code >= 200 && code < 300) || code == 404) return res;
      final retryable = code == 429 || code >= 500;
      if (retryable && attempt < maxRetries) {
        final ra = _retryAfter(res);
        await _sleep(ra ?? _backoff(attempt));
        attempt++;
        continue;
      }
      if (code == 429) {
        throw FoodApiException(
          FoodApiErrorKind.rateLimited,
          '$serviceName is rate limiting requests. Please wait a minute.',
          retryAfter: _retryAfter(res),
        );
      }
      if (code >= 500) {
        throw FoodApiException(
          FoodApiErrorKind.server,
          '$serviceName is having problems (HTTP $code). Try again later.',
        );
      }
      if (code == 401 || code == 403) {
        throw FoodApiException(
          FoodApiErrorKind.notConfigured,
          '$serviceName rejected the request (HTTP $code). Check the API key.',
        );
      }
      throw FoodApiException(
        FoodApiErrorKind.badResponse,
        '$serviceName returned an unexpected response (HTTP $code).',
      );
    }
  }

  Duration _backoff(int attempt) => baseBackoff * math.pow(2, attempt).toInt();

  Duration? _retryAfter(http.Response res) {
    final h = res.headers['retry-after'];
    final s = h == null ? null : int.tryParse(h.trim());
    if (s == null || s < 0) return null;
    return Duration(seconds: math.min(s, 30));
  }
}

/// Parses a JSON number that may arrive as num or string ("12,5" too).
double? parseNum(Object? v) {
  if (v == null) return null;
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is String) {
    final d = double.tryParse(v.trim().replaceAll(',', '.'));
    return d != null && d.isFinite ? d : null;
  }
  return null;
}
