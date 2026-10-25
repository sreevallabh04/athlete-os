import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/redact.dart';

/// Something a home-screen surface asked the app to do.
sealed class SurfaceEvent {
  const SurfaceEvent();

  static SurfaceEvent? fromMap(Object? raw) {
    if (raw is! Map) return null;
    switch (raw['type']) {
      case 'link':
        final uri = raw['uri'];
        return uri is String ? SurfaceLinkEvent(uri) : null;
      case 'water_queued':
        return const SurfaceWaterQueuedEvent();
    }
    return null;
  }
}

/// An `athleteos://open/...` link (widget tap, launcher shortcut, other app).
class SurfaceLinkEvent extends SurfaceEvent {
  const SurfaceLinkEvent(this.uri);
  final String uri;
}

/// The widget / tile appended water to the native queue.
class SurfaceWaterQueuedEvent extends SurfaceEvent {
  const SurfaceWaterQueuedEvent();
}

/// Native side of the home-screen surfaces
/// (`android/.../surfaces/SurfacesChannels.kt`). Every method is safe when
/// the platform side is missing (tests, non-Android) and never throws.
abstract interface class SurfacesPlatform {
  /// The link that launched the activity, if any (consumed on read).
  Future<String?> getInitialLink();

  /// Live links and queue notifications while the engine is attached.
  Stream<SurfaceEvent> get events;

  /// Pending native water entries (raw maps; parsed by the drainer).
  Future<List<Object?>> peekWaterQueue();

  /// Removes entries that were stored (or rejected) from the native queue.
  Future<void> ackWaterQueue(List<String> ids);

  /// Stores the snapshot JSON and re-renders every placed widget.
  Future<bool> updateWidget(String snapshotJson);
}

class MethodChannelSurfacesPlatform implements SurfacesPlatform {
  static const _channel = MethodChannel('athlete_os/surfaces');
  static const _events = EventChannel('athlete_os/surfaces/events');

  Stream<SurfaceEvent>? _stream;

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('surfaces.$method failed: ${redactSecrets(e.toString())}');
      return null;
    }
  }

  @override
  Future<String?> getInitialLink() => _call<String>('getInitialLink');

  @override
  Stream<SurfaceEvent> get events => _stream ??= _events
      .receiveBroadcastStream()
      .map(SurfaceEvent.fromMap)
      .where((e) => e != null)
      .cast<SurfaceEvent>()
      .handleError((Object _) {})
      .asBroadcastStream();

  @override
  Future<List<Object?>> peekWaterQueue() async =>
      (await _call<List<Object?>>('peekWaterQueue')) ?? const [];

  @override
  Future<void> ackWaterQueue(List<String> ids) async {
    if (ids.isEmpty) return;
    await _call<bool>('ackWaterQueue', {'ids': ids});
  }

  @override
  Future<bool> updateWidget(String snapshotJson) async =>
      (await _call<bool>('updateWidget', {'json': snapshotJson})) ?? false;
}

/// In-memory platform for tests and non-Android hosts.
class FakeSurfacesPlatform implements SurfacesPlatform {
  final controller = StreamController<SurfaceEvent>.broadcast();
  final List<Map<String, Object?>> queue = [];
  final List<String> widgetUpdates = [];
  final List<List<String>> acks = [];
  String? initialLink;

  /// When true, acks are recorded but entries stay queued (simulates an ack
  /// lost because the process died between store and ack).
  bool dropAcks = false;

  @override
  Future<String?> getInitialLink() async {
    final l = initialLink;
    initialLink = null;
    return l;
  }

  @override
  Stream<SurfaceEvent> get events => controller.stream;

  @override
  Future<List<Object?>> peekWaterQueue() async => List.of(queue);

  @override
  Future<void> ackWaterQueue(List<String> ids) async {
    acks.add(ids);
    if (!dropAcks) queue.removeWhere((e) => ids.contains(e['id']));
  }

  @override
  Future<bool> updateWidget(String snapshotJson) async {
    widgetUpdates.add(snapshotJson);
    return true;
  }
}

final surfacesPlatformProvider = Provider<SurfacesPlatform>(
  (ref) => MethodChannelSurfacesPlatform(),
);
