import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/redact.dart';
import '../db/database.dart';
import '../providers.dart';

/// Integration identifiers used across the app.
abstract final class Providers {
  static const healthConnect = 'health_connect';
  static const hevy = 'hevy';
  static const strava = 'strava';
  static const googleCalendar = 'google_calendar';
  static const openFoodFacts = 'open_food_facts';
  static const usda = 'usda';
  static const aiBackend = 'ai_backend';
}

/// Connection states. Never report `connected` unless a real call succeeded.
abstract final class ConnectionStates {
  static const connected = 'connected';
  static const disconnected = 'disconnected';
  static const needsSetup = 'needs_setup';
  static const awaitingCredentials = 'awaiting_credentials';
  static const error = 'error';
}

class IntegrationStatusRepository {
  IntegrationStatusRepository(this._db);
  final AppDatabase _db;

  Stream<List<IntegrationConnection>> watchAll() =>
      _db.select(_db.integrationConnections).watch();

  Stream<IntegrationConnection?> watch(String provider) => (_db.select(
    _db.integrationConnections,
  )..where((c) => c.provider.equals(provider))).watchSingleOrNull();

  Future<IntegrationConnection?> get(String provider) => (_db.select(
    _db.integrationConnections,
  )..where((c) => c.provider.equals(provider))).getSingleOrNull();

  Future<void> setStatus(
    String provider,
    String status, {
    List<String>? scopes,
    String? error,
    bool clearError = false,
    Map<String, Object?>? meta,
  }) async {
    final now = DateTime.now().toUtc();
    final existing = await get(provider);
    await _db
        .into(_db.integrationConnections)
        .insertOnConflictUpdate(
          IntegrationConnectionsCompanion(
            provider: Value(provider),
            status: Value(status),
            scopesJson: scopes != null
                ? Value(jsonEncode(scopes))
                : Value(existing?.scopesJson ?? '[]'),
            connectedAt: status == ConnectionStates.connected
                ? Value(existing?.connectedAt ?? now)
                : Value(existing?.connectedAt),
            lastSyncAt: Value(existing?.lastSyncAt),
            lastAttemptAt: Value(now),
            lastError: clearError || status == ConnectionStates.connected
                ? const Value(null)
                : Value(
                    error != null ? redactSecrets(error) : existing?.lastError,
                  ),
            cursor: Value(existing?.cursor),
            metaJson: meta != null
                ? Value(jsonEncode(meta))
                : Value(existing?.metaJson),
          ),
        );
  }

  Future<void> recordSync(
    String provider, {
    String? cursor,
    String? error,
  }) async {
    final now = DateTime.now().toUtc();
    await (_db.update(
      _db.integrationConnections,
    )..where((c) => c.provider.equals(provider))).write(
      IntegrationConnectionsCompanion(
        lastAttemptAt: Value(now),
        lastSyncAt: error == null ? Value(now) : const Value.absent(),
        lastError: Value(error == null ? null : redactSecrets(error)),
        cursor: cursor != null ? Value(cursor) : const Value.absent(),
      ),
    );
  }
}

final integrationStatusRepositoryProvider =
    Provider<IntegrationStatusRepository>(
      (ref) => IntegrationStatusRepository(ref.watch(databaseProvider)),
    );

final integrationStatusesProvider = StreamProvider<List<IntegrationConnection>>(
  (ref) => ref.watch(integrationStatusRepositoryProvider).watchAll(),
);
