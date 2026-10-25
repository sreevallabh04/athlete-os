import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keys for secrets kept in the platform keystore. Never log their values.
abstract final class SecretKeys {
  static const hevyApiKey = 'hevy_api_key';
  static const stravaAccessToken = 'strava_access_token';

  /// Epoch seconds (string).
  static const stravaExpiresAt = 'strava_expires_at';
}

/// Minimal secret storage abstraction so tests don't touch platform channels.
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSecretStore implements SecretStore {
  const SecureSecretStore([this._storage = const FlutterSecureStorage()]);
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class InMemorySecretStore implements SecretStore {
  InMemorySecretStore([Map<String, String>? initial]) : values = {...?initial};
  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

final secretStoreProvider = Provider<SecretStore>(
  (ref) => const SecureSecretStore(),
);
