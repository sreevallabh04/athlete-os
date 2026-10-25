import '../domain/health_types.dart';
import 'health_data_source.dart';

/// In-memory [HealthDataSource] for tests and previews. Never used in
/// production builds unless explicitly overridden.
class FakeHealthDataSource implements HealthDataSource {
  FakeHealthDataSource({
    this.status = HcSdkStatus.available,
    Set<HcDataType>? granted,
    List<HcRecord>? records,
    this.historyAuthorized = false,
    this.grantOnRequest = true,
  }) : granted = granted ?? {},
       records = records ?? [];

  HcSdkStatus status;
  Set<HcDataType> granted;
  List<HcRecord> records;
  bool historyAuthorized;
  bool grantOnRequest;

  /// Types that throw when read (simulates partial failures).
  final Set<HcDataType> failingTypes = {};

  /// Explicit step totals per local-midnight start; otherwise steps are
  /// summed from [records] (simple sum — the fake has no dedupe).
  final Map<DateTime, int> stepTotals = {};

  int readCalls = 0;
  int requestCalls = 0;
  int openSettingsCalls = 0;

  @override
  Future<void> configure() async {}

  @override
  Future<HcSdkStatus> sdkStatus() async => status;

  @override
  Future<void> installOrUpdate() async {}

  @override
  Future<bool> hasPermissions(List<HcDataType> types) async =>
      status == HcSdkStatus.available && types.every(granted.contains);

  @override
  Future<bool> requestPermissions(List<HcDataType> types) async {
    requestCalls++;
    if (grantOnRequest) granted.addAll(types);
    return grantOnRequest;
  }

  @override
  Future<bool> isHistoryAvailable() async => true;

  @override
  Future<bool> isHistoryAuthorized() async => historyAuthorized;

  @override
  Future<bool> requestHistory() async {
    historyAuthorized = grantOnRequest;
    return historyAuthorized;
  }

  @override
  Future<int?> totalSteps(DateTime start, DateTime end) async {
    if (!granted.contains(HcDataType.steps)) {
      throw StateError('SecurityException: READ_STEPS not granted');
    }
    if (failingTypes.contains(HcDataType.steps)) return null;
    if (stepTotals.containsKey(start)) return stepTotals[start];
    var sum = 0.0;
    for (final r in records) {
      if (r.type == HcDataType.steps &&
          !r.start.isBefore(start) &&
          r.start.isBefore(end)) {
        sum += r.value;
      }
    }
    return sum.round();
  }

  @override
  Future<List<HcRecord>> read(
    HcDataType type,
    DateTime start,
    DateTime end,
  ) async {
    readCalls++;
    if (!granted.contains(type)) {
      throw StateError('SecurityException: ${type.name} not granted');
    }
    if (failingTypes.contains(type)) {
      throw StateError('Simulated failure reading ${type.name}');
    }
    bool overlaps(HcRecord r) => r.start == r.end
        ? !r.start.isBefore(start) && r.start.isBefore(end)
        : r.end.isAfter(start) && r.start.isBefore(end);
    return records.where((r) => r.type == type && overlaps(r)).toList();
  }

  @override
  Future<bool> openSettings() async {
    openSettingsCalls++;
    return true;
  }
}
