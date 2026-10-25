import 'package:athlete_os/features/life/application/notifications/notification_gateway.dart';
import 'package:athlete_os/features/life/domain/reminder_kinds.dart';
import 'package:timezone/timezone.dart' as tz;

/// In-memory gateway that records what would be scheduled on Android.
class FakeNotificationGateway implements NotificationGateway {
  FakeNotificationGateway({this.enabled = true, this.exact = false});

  bool? enabled;
  bool? exact;
  final Map<int, (NotificationRequest, tz.TZDateTime, bool)> pending = {};
  final List<NotificationRequest> shown = [];
  final List<ReminderChannel> channels = [];
  int cancelCalls = 0;
  int permissionRequests = 0;

  @override
  Future<bool> initialize({
    required void Function(NotificationTap) onTap,
  }) async => true;

  @override
  Future<void> createChannels(List<ReminderChannel> c) async =>
      channels.addAll(c);

  @override
  Future<bool?> notificationsEnabled() async => enabled;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    enabled = true;
    return true;
  }

  @override
  Future<bool?> canScheduleExact() async => exact;

  @override
  Future<bool> requestExactAlarms() async {
    exact = true;
    return true;
  }

  @override
  Future<void> show(NotificationRequest request) async => shown.add(request);

  @override
  Future<void> schedule(
    NotificationRequest request,
    tz.TZDateTime when, {
    required bool exact,
  }) async {
    pending[request.id] = (request, when, exact);
  }

  @override
  Future<void> cancel(int id) async {
    cancelCalls++;
    pending.remove(id);
  }

  @override
  Future<List<int>> pendingIds() async => pending.keys.toList();

  @override
  Future<bool> openSystemSettings() async => true;

  @override
  Future<NotificationTap?> launchTap() async => null;
}
