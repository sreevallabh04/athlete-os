import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/health_data_source.dart';
import '../data/health_settings.dart';
import '../domain/health_types.dart';
import 'health_providers.dart';
import 'health_sync_service.dart';

enum GroupEnableResult { granted, partial, denied, unavailable }

/// Enables/disables permission groups. Requests only the types in the group
/// the user turned on, after the explanation sheet has been shown.
class HealthPermissionController {
  HealthPermissionController({
    required HealthDataSource source,
    required this._settings,
    required this._sync,
  }) : _ds = source;

  final HealthDataSource _ds;
  final HealthSettings _settings;
  final HealthSyncService _sync;

  Future<GroupEnableResult> enableGroup(HealthGroup group) async {
    if (await _ds.sdkStatus() != HcSdkStatus.available) {
      return GroupEnableResult.unavailable;
    }
    if (!await _ds.hasPermissions(group.types)) {
      await _ds.requestPermissions(group.types);
    }
    // Re-check per type: the user may grant only part of the group.
    var grantedCount = 0;
    for (final t in group.types) {
      if (await _ds.hasPermissions([t])) grantedCount++;
    }
    if (grantedCount == 0) return GroupEnableResult.denied;
    await _settings.setGroupEnabled(group, true);
    // Import immediately (full window so the new types get history).
    unawaited(
      _sync.sync(
        days: HealthSyncService.fullWindowDays,
        trigger: SyncTrigger.permissionChange,
      ),
    );
    return grantedCount == group.types.length
        ? GroupEnableResult.granted
        : GroupEnableResult.partial;
  }

  /// Stops importing the group. Health Connect permissions themselves can
  /// only be revoked by the user in Health Connect.
  Future<void> disableGroup(HealthGroup group) =>
      _settings.setGroupEnabled(group, false);

  Future<bool> requestHistory() async {
    if (await _ds.sdkStatus() != HcSdkStatus.available) return false;
    if (!await _ds.isHistoryAvailable()) return false;
    final ok = await _ds.isHistoryAuthorized() || await _ds.requestHistory();
    await _settings.setHistoryOptIn(ok);
    return ok;
  }
}

final healthPermissionControllerProvider = Provider<HealthPermissionController>(
  (ref) => HealthPermissionController(
    source: ref.watch(healthDataSourceProvider),
    settings: ref.watch(healthSettingsProvider),
    sync: ref.watch(healthSyncServiceProvider),
  ),
);
