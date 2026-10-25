import 'dart:async';

/// Rate-limits widget pushes to at most one per [interval].
///
/// * The first value after a quiet period is pushed immediately (leading
///   edge) so a change shows up on the home screen without delay.
/// * Values arriving during the cooldown are coalesced; only the latest is
///   pushed when the cooldown ends (trailing edge).
/// * Values whose [keyOf] equals the last pushed value are skipped.
/// * [flush] pushes a pending value now (e.g. when the app goes to the
///   background) without waiting for the cooldown.
///
/// Timer-based only (no wall clock), so it is deterministic under fake time.
class PushThrottle<T> {
  PushThrottle({required this.interval, required this.push, this.keyOf});

  final Duration interval;
  final Future<void> Function(T value) push;

  /// Content key; equal keys are not pushed twice in a row.
  final String Function(T value)? keyOf;

  Timer? _cooldown;
  T? _pending;
  bool _hasPending = false;
  String? _lastKey;
  bool _disposed = false;

  /// Number of pushes performed (for tests/diagnostics).
  int pushes = 0;

  bool get hasPending => _hasPending;

  void add(T value) {
    if (_disposed) return;
    final key = keyOf?.call(value);
    if (key != null && key == _lastKey) {
      // Back to what the widget already shows: nothing left to push.
      _pending = null;
      _hasPending = false;
      return;
    }
    if (_cooldown == null) {
      _send(value, key);
      _startCooldown();
    } else {
      _pending = value;
      _hasPending = true;
    }
  }

  /// Pushes the pending value (if any) immediately and restarts the cooldown.
  void flush() {
    if (_disposed || !_hasPending) return;
    final v = _pending as T;
    _pending = null;
    _hasPending = false;
    _send(v, keyOf?.call(v));
    _startCooldown();
  }

  /// Forgets the last pushed key so the next value is always pushed (e.g.
  /// after the native widget store was cleared).
  void invalidate() => _lastKey = null;

  void dispose() {
    _disposed = true;
    _cooldown?.cancel();
    _cooldown = null;
    _pending = null;
    _hasPending = false;
  }

  void _startCooldown() {
    _cooldown?.cancel();
    _cooldown = Timer(interval, _onCooldownEnd);
  }

  void _onCooldownEnd() {
    _cooldown = null;
    if (_disposed || !_hasPending) return;
    final v = _pending as T;
    _pending = null;
    _hasPending = false;
    final key = keyOf?.call(v);
    if (key != null && key == _lastKey) return;
    _send(v, key);
    _startCooldown();
  }

  void _send(T value, String? key) {
    _lastKey = key;
    pushes++;
    unawaited(push(value).then((_) {}, onError: (Object _) => _lastKey = null));
  }
}
