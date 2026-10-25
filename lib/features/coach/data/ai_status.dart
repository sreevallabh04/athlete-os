import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ai_backend.dart';

/// Live `ai-status` result (null when the backend is not ready).
final aiStatusProvider = FutureProvider.autoDispose<Map<String, Object?>?>((
  ref,
) async {
  final backend = ref.watch(aiBackendClientProvider);
  if (backend.state != AiBackendState.ready) return null;
  return backend.status();
});

/// Result of one "Test connection" probe per key, kept for the session so
/// settings can show live latency bars.
class ProviderProbe {
  const ProviderProbe({
    required this.provider,
    required this.alias,
    required this.ok,
    this.latencyMs,
    this.error,
  });

  final String provider;
  final String alias;
  final bool ok;
  final int? latencyMs;
  final String? error;

  static List<ProviderProbe> parse(Map<String, Object?> res) => [
    for (final r in (res['results'] as List? ?? const []))
      if (r is Map)
        ProviderProbe(
          provider: '${r['provider'] ?? ''}',
          alias: '${r['alias'] ?? ''}',
          ok: r['ok'] == true,
          latencyMs: (r['latency_ms'] as num?)?.toInt(),
          error: r['error']?.toString(),
        ),
  ];
}

class ProviderProbes extends Notifier<Map<String, List<ProviderProbe>>> {
  @override
  Map<String, List<ProviderProbe>> build() => const {};

  void record(String provider, List<ProviderProbe> probes) =>
      state = {...state, provider: probes};
}

final providerProbesProvider =
    NotifierProvider<ProviderProbes, Map<String, List<ProviderProbe>>>(
      ProviderProbes.new,
    );

/// Short display name for a provider id.
String providerShortName(String? id) => switch (id) {
  'gemini' => 'Gemini',
  'groq' => 'Groq',
  'anthropic' => 'Claude',
  'openai' => 'OpenAI',
  null || '' => 'AI core',
  _ => id,
};

enum LinkTone { online, fallback, degraded, offline, linking }

/// The Coach's honest link status line ("Online · Gemini").
class CoachLink {
  const CoachLink(this.tone, this.label, this.detail, {this.latency});
  final LinkTone tone;
  final String label;
  final String detail;
  final Duration? latency;
}

/// Pure link derivation (unit-tested). [status] is the `ai-status` body;
/// [lastProvider]/[fallbackUsed] come from the latest coach response, which
/// is the most truthful signal once there is one.
CoachLink deriveCoachLink({
  required AiBackendState backend,
  Map<String, Object?>? status,
  bool statusLoading = false,
  bool statusFailed = false,
  String? lastProvider,
  bool fallbackUsed = false,
  Duration? lastLatency,
  String? lastErrorCode,
}) {
  switch (backend) {
    case AiBackendState.unconfigured:
      return const CoachLink(LinkTone.offline, 'Offline', 'No backend');
    case AiBackendState.signedOut:
      return const CoachLink(LinkTone.linking, 'Standby', 'Signing in');
    case AiBackendState.ready:
      break;
  }
  const linkFaults = {
    'network',
    'timeout',
    'providers_unavailable',
    'upstream_error',
    'no_provider_configured',
  };
  if (lastErrorCode != null && linkFaults.contains(lastErrorCode)) {
    return CoachLink(
      LinkTone.degraded,
      'Degraded',
      lastErrorCode == 'timeout' ? 'Link timeout' : 'Link fault',
    );
  }
  if (lastProvider != null) {
    return CoachLink(
      fallbackUsed ? LinkTone.fallback : LinkTone.online,
      fallbackUsed ? 'Fallback' : 'Online',
      providerShortName(lastProvider),
      latency: lastLatency,
    );
  }
  if (statusLoading) {
    return const CoachLink(LinkTone.linking, 'Linking', 'AI core');
  }
  if (statusFailed || status == null) {
    return const CoachLink(LinkTone.online, 'Online', 'Unverified');
  }
  final providers = (status['providers'] as List? ?? const [])
      .whereType<Map>()
      .toList();
  if (providers.isEmpty) {
    return const CoachLink(LinkTone.online, 'Online', 'AI core');
  }
  bool healthy(Map p) =>
      p['configured'] == true &&
      p['circuit'] != 'open' &&
      (p['aliases'] as List? ?? const []).whereType<Map>().any(
        (a) => a['status'] == 'ok',
      );
  final order = (status['provider_order'] as List? ?? const [])
      .map((e) => '$e')
      .toList();
  final configured = [
    for (final id in order)
      ?providers.where((p) => p['provider'] == id).firstOrNull,
    for (final p in providers)
      if (!order.contains(p['provider'])) p,
  ].where((p) => p['configured'] == true).toList();
  if (configured.isEmpty) {
    return const CoachLink(LinkTone.degraded, 'Degraded', 'No provider keys');
  }
  final first = configured.first;
  if (healthy(first)) {
    return CoachLink(
      LinkTone.online,
      'Online',
      providerShortName('${first['provider']}'),
    );
  }
  final backup = configured.skip(1).where(healthy).firstOrNull;
  if (backup != null) {
    return CoachLink(
      LinkTone.fallback,
      'Fallback',
      providerShortName('${backup['provider']}'),
    );
  }
  return const CoachLink(LinkTone.degraded, 'Degraded', 'Providers down');
}
