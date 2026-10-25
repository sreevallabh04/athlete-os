/// Human-readable labels for the apps and devices that wrote health data.
library;

const samsungHealthPackage = 'com.sec.android.app.shealth';
const googleFitPackage = 'com.google.android.apps.fitness';
const healthConnectPackage = 'com.google.android.apps.healthdata';

/// Maps an Android package name to a display name.
String sourceAppLabel(String? package) {
  if (package == null || package.trim().isEmpty) return 'Unknown app';
  return switch (package.trim()) {
    samsungHealthPackage => 'Samsung Health',
    googleFitPackage => 'Google Fit',
    healthConnectPackage => 'Health Connect',
    'user_input' => 'Entered in Health Connect',
    _ => package.trim(),
  };
}

/// Comma-separated display list for several packages (deduplicated, sorted).
String sourcesLabel(Iterable<String> packages) {
  final labels =
      packages
          .where((p) => p.trim().isNotEmpty)
          .expand((p) => p.split(','))
          .map((p) => sourceAppLabel(p.trim()))
          .toSet()
          .toList()
        ..sort();
  return labels.join(', ');
}

/// Device type from Health Connect record metadata when available.
///
/// The `health` plugin (13.3.2) does not forward `Metadata.device` on
/// Android, so this usually returns `unknown`. We never guess the device from
/// the app name: Samsung Health writes both phone- and watch-recorded data.
String deviceTypeFromMetadata(Map<String, Object?>? metadata) {
  if (metadata == null) return 'unknown';
  final raw =
      (metadata['device_type'] ?? metadata['deviceType'] ?? metadata['device'])
          ?.toString()
          .toLowerCase();
  if (raw == null) return 'unknown';
  if (raw.contains('watch') || raw == '1') return 'watch';
  if (raw.contains('phone') || raw == '2') return 'phone';
  if (raw.contains('scale') || raw == '3') return 'scale';
  return 'unknown';
}

String deviceLabel(String? device) => switch (device) {
  'watch' => 'Watch',
  'phone' => 'Phone',
  'scale' => 'Scale',
  'manual' => 'Manual entry',
  _ => 'Device unknown',
};
