/// Compile-time client configuration supplied with
/// `flutter run --dart-define-from-file=config/dev.json`.
///
/// Only PUBLIC identifiers belong here (Supabase anon key, OAuth client IDs).
/// Provider API keys and OAuth client secrets live on the server only.
abstract final class Env {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const stravaClientId = String.fromEnvironment('STRAVA_CLIENT_ID');
  static const googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
  );

  /// Contact e-mail sent in the Open Food Facts User-Agent, as their API
  /// policy requires (`AppName/Version (email)`).
  static const offContactEmail = String.fromEnvironment(
    'OFF_CONTACT_EMAIL',
    defaultValue: 'athleteos-dev@example.com',
  );
  static const usdaApiKey = String.fromEnvironment('USDA_API_KEY');

  /// USDA's official public demo key (≈30 requests/hour per IP). Used when no
  /// personal key is configured so food search works out of the box; a free
  /// personal key from https://api.data.gov/signup lifts the limit.
  static const usdaDemoKey = 'DEMO_KEY';
  static bool get usdaIsDemo => usdaApiKey.isEmpty;
  static String get usdaEffectiveKey => usdaIsDemo ? usdaDemoKey : usdaApiKey;

  static bool get hasSupabase =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
  static bool get hasStrava => stravaClientId.isNotEmpty && hasSupabase;
  static bool get hasGoogle => googleWebClientId.isNotEmpty;

  static const appVersion = '1.0.0';
  static const userAgent = 'AthleteOS/$appVersion';
}
