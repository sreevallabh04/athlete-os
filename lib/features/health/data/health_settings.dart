import '../../../data/repositories/settings_repository.dart';
import '../domain/health_types.dart';

/// AppSettings keys owned by the health feature (all prefixed `health.`).
abstract final class HealthSettingKeys {
  /// JSON list of [HealthGroup] names the user has enabled.
  static const enabledGroups = 'health.enabled_groups';

  /// Whether the user opted in to READ_HEALTH_DATA_HISTORY (older than 30
  /// days before first grant).
  static const historyOptIn = 'health.history_opt_in';
}

/// Typed access to the health feature's settings.
class HealthSettings {
  HealthSettings(this._settings);
  final SettingsRepository _settings;

  static Set<HealthGroup> parseGroups(Object? raw) {
    if (raw is! List) return {};
    return {
      for (final v in raw)
        if (v is String && HealthGroup.tryParse(v) != null)
          HealthGroup.tryParse(v)!,
    };
  }

  Future<Set<HealthGroup>> enabledGroups() async =>
      parseGroups(await _settings.get<Object>(HealthSettingKeys.enabledGroups));

  Stream<Set<HealthGroup>> watchEnabledGroups() =>
      _settings.watch<Object>(HealthSettingKeys.enabledGroups).map(parseGroups);

  Future<void> setGroupEnabled(HealthGroup group, bool enabled) async {
    final current = await enabledGroups();
    enabled ? current.add(group) : current.remove(group);
    await _settings.set(HealthSettingKeys.enabledGroups, [
      for (final g in HealthGroup.values)
        if (current.contains(g)) g.name,
    ]);
  }

  Future<bool> historyOptIn() async =>
      (await _settings.get<bool>(HealthSettingKeys.historyOptIn)) ?? false;

  Future<void> setHistoryOptIn(bool v) =>
      _settings.set(HealthSettingKeys.historyOptIn, v);
}
