import 'dart:convert';

/// FNV-1a 64-bit hash as 16 lowercase hex chars. Mirrors the Kotlin
/// implementation in `NotificationParser.dedupeHash` (Dart VM ints wrap at
/// 64 bits, like Kotlin Longs).
String fnv1a64Hex(String input) {
  var h = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  for (final b in utf8.encode(input)) {
    h ^= b;
    h *= prime;
  }
  final hi = (h >> 32) & 0xFFFFFFFF;
  final lo = h & 0xFFFFFFFF;
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}

/// Dedupe hash: package + conversation + text + post time rounded to 1 s.
String dedupeHashFor({
  required String packageName,
  required String conversationKey,
  required String text,
  required DateTime postedAt,
}) => fnv1a64Hex(
  '$packageName|$conversationKey|$text|'
  '${postedAt.millisecondsSinceEpoch ~/ 1000}',
);

/// Idempotency key for sending one specific draft exactly once.
String idempotencyKeyFor(String dedupeHash, String draftId) =>
    'r-${fnv1a64Hex('$dedupeHash:$draftId')}';

/// Content-free reference to a conversation for audit/log records (the raw
/// key may be a contact's name).
String conversationRef(String? conversationKey) =>
    conversationKey == null ? '-' : 'c-${fnv1a64Hex(conversationKey)}';
