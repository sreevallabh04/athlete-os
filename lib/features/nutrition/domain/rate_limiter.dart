/// Sliding-window rate limiter (client-side courtesy limits for public APIs).
class RateLimiter {
  RateLimiter({
    required this.maxCalls,
    required this.window,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int maxCalls;
  final Duration window;
  final DateTime Function() _now;
  final List<DateTime> _calls = [];

  void _prune(DateTime now) {
    _calls.removeWhere((t) => now.difference(t) >= window);
  }

  /// Records a call and returns null if allowed; otherwise returns how long
  /// to wait until a slot frees up (and records nothing).
  Duration? tryAcquire() {
    final now = _now();
    _prune(now);
    if (_calls.length >= maxCalls) {
      final oldest = _calls.first;
      return window - now.difference(oldest);
    }
    _calls.add(now);
    return null;
  }

  int get remaining {
    _prune(_now());
    return maxCalls - _calls.length;
  }
}
