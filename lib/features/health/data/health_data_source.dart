import '../domain/health_types.dart';

/// Gateway to Health Connect. The production implementation wraps the
/// `health` plugin; tests use [FakeHealthDataSource].
///
/// Implementations must never throw from status/permission queries — they
/// return a safe "not available / not granted" answer instead. Read methods
/// may throw; the sync service catches and records errors per data type.
abstract class HealthDataSource {
  /// One-time plugin setup. Safe to call repeatedly.
  Future<void> configure();

  Future<HcSdkStatus> sdkStatus();

  /// Opens the Play Store page to install/update Health Connect (Android 13
  /// and lower). No-op on Android 14+ where it is part of the OS.
  Future<void> installOrUpdate();

  /// Whether READ access is granted for every type in [types].
  Future<bool> hasPermissions(List<HcDataType> types);

  /// Shows the Health Connect permission dialog for READ access to [types].
  Future<bool> requestPermissions(List<HcDataType> types);

  Future<bool> isHistoryAvailable();
  Future<bool> isHistoryAuthorized();
  Future<bool> requestHistory();

  /// Total steps in [start, end) via the Health Connect aggregate API
  /// (de-duplicated across apps/devices). Null when unavailable.
  Future<int?> totalSteps(DateTime start, DateTime end);

  /// Raw records of [type] overlapping [start, end).
  Future<List<HcRecord>> read(HcDataType type, DateTime start, DateTime end);

  /// Opens the Health Connect settings / permission management screen.
  /// Returns false when this cannot be done programmatically.
  Future<bool> openSettings();
}
