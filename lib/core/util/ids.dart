import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// New random v4 UUID for client-generated primary keys.
String newId() => _uuid.v4();

/// Deterministic v5 UUID so the same external record always maps to the same
/// local id (idempotent imports).
String stableId(String namespace, String externalId) =>
    _uuid.v5(Namespace.url.value, '$namespace:$externalId');
