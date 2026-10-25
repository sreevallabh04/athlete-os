/// Device IANA timezone, resolved once at startup by `nutritionBootstrap`.
/// Falls back to the platform abbreviation (e.g. "IST") until then.
abstract final class DeviceTz {
  static String? iana;

  static String name(DateTime now) {
    final i = iana;
    if (i != null && i.isNotEmpty) return i;
    final n = now.timeZoneName;
    return n.isEmpty ? 'UTC' : n;
  }
}
