import 'package:intl/intl.dart';

abstract final class Fmt {
  static final _int = NumberFormat.decimalPattern();
  static final _oneDp = NumberFormat('#,##0.#');

  static String integer(num v) => _int.format(v.round());
  static String oneDp(num v) => _oneDp.format(v);
  static String grams(num v) => '${_oneDp.format(v)} g';
  static String kcal(num v) => '${_int.format(v.round())} kcal';
  static final _twoDp = NumberFormat('#,##0.##');

  /// 1750 → "1.75 L" (two decimals so 250 ml steps stay exact), 900 → "900 ml".
  static String ml(num v) =>
      v >= 1000 ? '${_twoDp.format(v / 1000)} L' : '${v.round()} ml';
  static String km(num meters) => '${(meters / 1000).toStringAsFixed(2)} km';

  /// 1:05:09 or 25:09
  static String duration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  /// Pace in min/km from seconds per km, e.g. 5:42 /km.
  static String pace(double secondsPerKm) {
    if (!secondsPerKm.isFinite || secondsPerKm <= 0) return '–';
    final total = secondsPerKm.round();
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')} /km';
  }

  static String time(DateTime t) => DateFormat.jm().format(t.toLocal());
  static String dayMonth(DateTime t) => DateFormat.MMMd().format(t.toLocal());
  static String weekdayDayMonth(DateTime t) =>
      DateFormat('EEE, d MMM').format(t.toLocal());

  /// "just now", "12 min ago", "3 h ago", "2 days ago".
  static String ago(DateTime t, DateTime now) {
    final d = now.difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    final days = d.inDays;
    return days == 1 ? 'yesterday' : '$days days ago';
  }
}
