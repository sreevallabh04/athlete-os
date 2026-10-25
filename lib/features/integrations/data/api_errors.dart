import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../../core/util/redact.dart';

/// Typed integration failures. Messages are always redacted and safe to show.
sealed class IntegrationException implements Exception {
  IntegrationException(String message) : message = redactSecrets(message);
  final String message;
  @override
  String toString() => message;
}

/// 401/403 from the provider (bad key, revoked/expired token).
class InvalidCredentialsException extends IntegrationException {
  InvalidCredentialsException([super.message = 'Invalid credentials']);
}

class RateLimitedException extends IntegrationException {
  RateLimitedException({this.retryAfter})
    : super(
        retryAfter == null
            ? 'Rate limit reached. Try again later.'
            : 'Rate limit reached. Try again in ${retryAfter.inMinutes + 1} min.',
      );
  final Duration? retryAfter;
}

class ApiException extends IntegrationException {
  ApiException(this.statusCode, String message) : super(message);
  final int statusCode;
}

class NetworkException extends IntegrationException {
  NetworkException([super.message = 'Network error. Check your connection.']);
}

/// Integration not configured for this build (missing client id / backend).
class AwaitingCredentialsException extends IntegrationException {
  AwaitingCredentialsException(super.message);
}

typedef Sleeper = Future<void> Function(Duration);

Future<void> realSleep(Duration d) => Future<void>.delayed(d);

/// Parses a Retry-After header (delta-seconds or HTTP date).
Duration? parseRetryAfter(String? value, {DateTime? now}) {
  if (value == null) return null;
  final secs = int.tryParse(value.trim());
  if (secs != null) return Duration(seconds: math.max(0, secs));
  try {
    final at = HttpDate.parse(value);
    final d = at.difference(now ?? DateTime.now().toUtc());
    return d.isNegative ? Duration.zero : d;
  } on FormatException {
    return null;
  } on HttpException {
    return null;
  }
}

/// Sends a request with retries on 429/5xx/timeouts using exponential
/// backoff with jitter, honouring Retry-After. Returns the final response
/// (which may still be an error status) or throws [NetworkException] /
/// [RateLimitedException] when attempts are exhausted.
Future<http.Response> sendWithRetry(
  Future<http.Response> Function() send, {
  int maxAttempts = 4,
  Duration baseDelay = const Duration(milliseconds: 800),
  Duration maxDelay = const Duration(seconds: 60),
  Duration timeout = const Duration(seconds: 20),
  Sleeper sleep = realSleep,
  math.Random? random,
  bool retryOn429 = true,
}) async {
  final rnd = random ?? math.Random();
  for (var attempt = 1; ; attempt++) {
    http.Response? res;
    Object? error;
    try {
      res = await send().timeout(timeout);
    } on TimeoutException catch (e) {
      error = e;
    } on SocketException catch (e) {
      error = e;
    } on http.ClientException catch (e) {
      error = e;
    }
    final retryable =
        error != null ||
        res!.statusCode == 429 ||
        (res.statusCode >= 500 && res.statusCode <= 599);
    if (!retryable) return res;
    final retryAfter = res == null
        ? null
        : parseRetryAfter(res.headers['retry-after']);
    if (!retryOn429 && res != null && res.statusCode == 429) {
      throw RateLimitedException(retryAfter: retryAfter);
    }
    if (attempt >= maxAttempts) {
      if (res != null && res.statusCode == 429) {
        throw RateLimitedException(retryAfter: retryAfter);
      }
      if (res != null) return res;
      throw NetworkException();
    }
    if (retryAfter != null && retryAfter > maxDelay) {
      // Waiting that long in the foreground is pointless; surface it.
      throw RateLimitedException(retryAfter: retryAfter);
    }
    final exp = baseDelay * math.pow(2, attempt - 1).toInt();
    final jitter = Duration(
      milliseconds: rnd.nextInt(math.max(1, baseDelay.inMilliseconds)),
    );
    var delay = retryAfter ?? exp + jitter;
    if (delay > maxDelay) delay = maxDelay;
    await sleep(delay);
  }
}
