import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:health/health.dart';

import '../../../core/util/redact.dart';
import '../domain/health_types.dart';
import 'health_data_source.dart';

/// Production [HealthDataSource] backed by the `health` plugin (13.3.2,
/// Health Connect only). Read-only: we never request write access.
class HealthConnectDataSource implements HealthDataSource {
  HealthConnectDataSource({Health? health}) : _healthOverride = health;

  final Health? _healthOverride;
  Health? _healthInstance;
  Health get _health => _healthInstance ??= _healthOverride ?? Health();
  bool _configured = false;

  /// Optional native hook for opening Health Connect settings (see
  /// docs/integrations/health-connect.md). Absent → [openSettings] returns
  /// false and the UI shows manual instructions.
  static const _settingsChannel = MethodChannel('athlete_os/health_connect');

  static const _readTimeout = Duration(seconds: 60);

  bool get _isAndroid {
    try {
      return !kIsWeb && Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  static HealthDataType toPlugin(HcDataType t) => switch (t) {
    HcDataType.steps => HealthDataType.STEPS,
    HcDataType.distance => HealthDataType.DISTANCE_DELTA,
    HcDataType.activeCalories => HealthDataType.ACTIVE_ENERGY_BURNED,
    HcDataType.totalCalories => HealthDataType.TOTAL_CALORIES_BURNED,
    HcDataType.exercise => HealthDataType.WORKOUT,
    HcDataType.heartRate => HealthDataType.HEART_RATE,
    HcDataType.restingHeartRate => HealthDataType.RESTING_HEART_RATE,
    HcDataType.sleepSession => HealthDataType.SLEEP_SESSION,
    HcDataType.weight => HealthDataType.WEIGHT,
  };

  void _log(String what, Object e) =>
      debugPrint('HealthConnect $what: ${redactSecrets(e.toString())}');

  @override
  Future<void> configure() async {
    if (_configured || !_isAndroid) return;
    try {
      await _health.configure();
      _configured = true;
    } catch (e) {
      _log('configure failed', e);
    }
  }

  @override
  Future<HcSdkStatus> sdkStatus() async {
    if (!_isAndroid) return HcSdkStatus.unsupported;
    try {
      final s = await _health.getHealthConnectSdkStatus();
      return switch (s) {
        HealthConnectSdkStatus.sdkAvailable => HcSdkStatus.available,
        HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired =>
          HcSdkStatus.needsUpdate,
        // minSdk is 28, so "unavailable" means the provider app is missing
        // (Android 9-13). Android 14+ always reports available.
        HealthConnectSdkStatus.sdkUnavailable => HcSdkStatus.needsInstall,
        null => HcSdkStatus.unsupported,
      };
    } catch (e) {
      _log('sdk status failed', e);
      return HcSdkStatus.unsupported;
    }
  }

  @override
  Future<void> installOrUpdate() async {
    if (!_isAndroid) return;
    try {
      await _health.installHealthConnect();
    } catch (e) {
      _log('install failed', e);
    }
  }

  @override
  Future<bool> hasPermissions(List<HcDataType> types) async {
    if (!_isAndroid || types.isEmpty) return false;
    try {
      await configure();
      final ok = await _health.hasPermissions(
        types.map(toPlugin).toList(),
        permissions: List.filled(types.length, HealthDataAccess.READ),
      );
      return ok ?? false;
    } catch (e) {
      _log('hasPermissions failed', e);
      return false;
    }
  }

  @override
  Future<bool> requestPermissions(List<HcDataType> types) async {
    if (!_isAndroid || types.isEmpty) return false;
    try {
      await configure();
      return await _health.requestAuthorization(
        types.map(toPlugin).toList(),
        permissions: List.filled(types.length, HealthDataAccess.READ),
      );
    } catch (e) {
      _log('requestAuthorization failed', e);
      return false;
    }
  }

  @override
  Future<bool> isHistoryAvailable() async {
    if (!_isAndroid) return false;
    try {
      return await _health.isHealthDataHistoryAvailable();
    } catch (e) {
      _log('history availability failed', e);
      return false;
    }
  }

  @override
  Future<bool> isHistoryAuthorized() async {
    if (!_isAndroid) return false;
    try {
      return await _health.isHealthDataHistoryAuthorized();
    } catch (e) {
      _log('history status failed', e);
      return false;
    }
  }

  @override
  Future<bool> requestHistory() async {
    if (!_isAndroid) return false;
    try {
      return await _health.requestHealthDataHistoryAuthorization();
    } catch (e) {
      _log('history request failed', e);
      return false;
    }
  }

  @override
  Future<int?> totalSteps(DateTime start, DateTime end) async {
    if (!_isAndroid) return null;
    await configure();
    return _health.getTotalStepsInInterval(start, end).timeout(_readTimeout);
  }

  @override
  Future<List<HcRecord>> read(
    HcDataType type,
    DateTime start,
    DateTime end,
  ) async {
    if (!_isAndroid) return const [];
    await configure();
    final points = await _health
        .getHealthDataFromTypes(
          types: [toPlugin(type)],
          startTime: start,
          endTime: end,
        )
        .timeout(_readTimeout);
    return [for (final p in points) _convert(type, p)];
  }

  static HcRecord _convert(HcDataType type, HealthDataPoint p) {
    final v = p.value;
    double value = 0;
    String? workoutType;
    double? distance;
    double? energy;
    double? steps;
    if (v is NumericHealthValue) {
      value = v.numericValue.toDouble();
    } else if (v is WorkoutHealthValue) {
      value = p.dateTo.difference(p.dateFrom).inSeconds / 60;
      workoutType = v.workoutActivityType.name;
      distance = v.totalDistance?.toDouble();
      energy = v.totalEnergyBurned?.toDouble();
      steps = v.totalSteps?.toDouble();
    }
    final summary = p.workoutSummary;
    if (summary != null) {
      workoutType ??= summary.workoutType;
      distance ??= summary.totalDistance.toDouble();
      energy ??= summary.totalEnergyBurned.toDouble();
      steps ??= summary.totalSteps.toDouble();
    }
    return HcRecord(
      uuid: p.uuid,
      type: type,
      value: value,
      unit: p.unit.name,
      start: p.dateFrom.toUtc(),
      end: p.dateTo.toUtc(),
      sourceApp: p.sourceName.isNotEmpty ? p.sourceName : p.sourceId,
      recordingMethod: p.recordingMethod.name,
      metadata: p.metadata,
      workoutType: workoutType,
      totalDistanceM: distance,
      totalEnergyKcal: energy,
      totalSteps: steps,
    );
  }

  @override
  Future<bool> openSettings() async {
    if (!_isAndroid) return false;
    try {
      final ok = await _settingsChannel.invokeMethod<bool>('openSettings');
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      _log('openSettings failed', e);
      return false;
    }
  }
}
