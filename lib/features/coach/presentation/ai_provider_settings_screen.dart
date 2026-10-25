import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/settings_repository.dart';
import '../data/ai_backend.dart';
import '../data/ai_preferences.dart';
import '../data/coach_auth.dart';

/// Live `ai-status` result (null when the backend is not ready).
final aiStatusProvider = FutureProvider.autoDispose<Map<String, Object?>?>((
  ref,
) async {
  final backend = ref.watch(aiBackendClientProvider);
  if (backend.state != AiBackendState.ready) return null;
  return backend.status();
});

final _consentProvider = StreamProvider.autoDispose.family<bool, String>(
  (ref, key) => ref
      .watch(settingsRepositoryProvider)
      .watch<bool>(key)
      .map((v) => v ?? false),
);

class AiProviderSettingsScreen extends ConsumerWidget {
  const AiProviderSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backendState = ref.watch(aiBackendStateProvider);
    return AppPage(
      title: 'AI providers',
      subtitle:
          'Provider keys live only on your Supabase backend. This device '
          'sends requests through the ai-chat edge function.',
      onRefresh: () async => ref.invalidate(aiStatusProvider),
      children: [
        const SectionHeader('Backend connection'),
        const _BackendSection(),
        if (backendState == AiBackendState.ready) ...[
          const SectionHeader('Providers', subtitle: 'Health of server keys'),
          const _ProvidersSection(),
          const SectionHeader('Usage this month'),
          const _UsageSection(),
        ],
        const SectionHeader('Preferences', subtitle: 'Sent with each request'),
        const _PreferencesSection(),
        const SectionHeader('Privacy & consent'),
        const _ConsentSection(),
        const SectionHeader('Costs'),
        const _CostDisclosure(),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _BackendSection extends ConsumerStatefulWidget {
  const _BackendSection();
  @override
  ConsumerState<_BackendSection> createState() => _BackendSectionState();
}

class _BackendSectionState extends ConsumerState<_BackendSection> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false;
  bool _working = false;
  String? _message;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f, {String? success}) async {
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      await f();
      if (success != null) _message = success;
    } catch (e) {
      _message = e is StateError ? e.message : 'Something went wrong.';
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(coachAuthProvider);
    final authState = ref.watch(coachAuthStateProvider).value ?? auth.current;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    if (!authState.configured) {
      return AppCard(
        accent: AppColors.warning,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_off_outlined, color: AppColors.warning),
                const SizedBox(width: AppSpacing.sm),
                Text('Awaiting credentials', style: t.titleSmall),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'The coach is off until a backend is connected. Setup:',
              style: t.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            ...[
              '1. Create a Supabase project and run `supabase db push`.',
              '2. Set provider keys as function secrets (e.g. '
                  'ANTHROPIC_API_KEY) and deploy ai-chat and ai-status.',
              '3. Enable Anonymous and/or Email sign-in in Supabase Auth.',
              '4. Put SUPABASE_URL and SUPABASE_ANON_KEY in config/dev.json '
                  'and run with --dart-define-from-file=config/dev.json.',
            ].map(
              (s) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(s, style: t.bodySmall),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'See docs/AI_AGENT.md for details.',
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    if (authState.signedIn) {
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.verified_user_outlined,
                  color: AppColors.success,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    authState.isAnonymous
                        ? 'Signed in anonymously (this device)'
                        : 'Signed in as ${authState.email ?? 'account'}',
                    style: t.titleSmall,
                  ),
                ),
              ],
            ),
            if (authState.isAnonymous)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  'Anonymous accounts are bound to this install. Signing out '
                  'or reinstalling loses access to its usage history.',
                  style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                OutlinedButton(
                  onPressed: _working
                      ? null
                      : () => ref.invalidate(aiStatusProvider),
                  child: const Text('Refresh status'),
                ),
                TextButton(
                  onPressed: _working ? null : () => _run(auth.signOut),
                  child: const Text('Sign out'),
                ),
              ],
            ),
            if (_message != null) Text(_message!, style: t.bodySmall),
          ],
        ),
      );
    }

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sign in to your AI backend', style: t.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Anonymous sign-in is quickest: the account is tied to this '
            'device. Use an email code to keep the same account across '
            'devices.',
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.tonal(
            onPressed: _working ? null : () => _run(auth.signInAnonymously),
            child: const Text('Continue anonymously'),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          if (_codeSent)
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Code from the email',
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              OutlinedButton(
                onPressed: _working
                    ? null
                    : () => _run(() async {
                        if (!_email.text.contains('@')) {
                          throw StateError('Enter a valid email address.');
                        }
                        await auth.sendEmailCode(_email.text);
                        _codeSent = true;
                      }, success: 'Check your email for a sign-in code.'),
                child: Text(_codeSent ? 'Resend code' : 'Email me a code'),
              ),
              if (_codeSent)
                FilledButton(
                  onPressed: _working
                      ? null
                      : () => _run(
                          () => auth.verifyEmailCode(_email.text, _code.text),
                        ),
                  child: const Text('Verify'),
                ),
            ],
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(_message!, style: t.bodySmall),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _ProvidersSection extends ConsumerStatefulWidget {
  const _ProvidersSection();
  @override
  ConsumerState<_ProvidersSection> createState() => _ProvidersSectionState();
}

class _ProvidersSectionState extends ConsumerState<_ProvidersSection> {
  final _testing = <String>{};
  final _results = <String, String>{};

  Future<void> _test(String provider) async {
    setState(() => _testing.add(provider));
    try {
      final res = await ref
          .read(aiBackendClientProvider)
          .testProviders(provider: provider);
      final lines = <String>[];
      for (final r in (res['results'] as List? ?? const [])) {
        if (r is! Map) continue;
        lines.add(
          '${r['alias']}: ${r['ok'] == true ? 'OK' : 'failed'}'
          '${r['latency_ms'] != null ? ' · ${r['latency_ms']} ms' : ''}'
          '${r['error'] != null ? ' · ${r['error']}' : ''}',
        );
      }
      _results[provider] = lines.isEmpty ? 'No keys tested.' : lines.join('\n');
      ref.invalidate(aiStatusProvider);
    } on AiBackendException catch (e) {
      _results[provider] = e.message;
    } finally {
      if (mounted) setState(() => _testing.remove(provider));
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(aiStatusProvider);
    final t = Theme.of(context).textTheme;
    return status.when(
      loading: () => const LoadingState(),
      error: (e, _) => ErrorState(
        message: e is AiBackendException
            ? e.message
            : 'Could not load provider status.',
        onRetry: () => ref.invalidate(aiStatusProvider),
      ),
      data: (s) {
        final providers = (s?['providers'] as List? ?? const [])
            .whereType<Map>()
            .toList();
        if (providers.isEmpty) {
          return const EmptyState(
            icon: Icons.key_off_outlined,
            title: 'No provider keys configured',
            message:
                'Set ANTHROPIC_API_KEY, OPENAI_API_KEY or GEMINI_API_KEY '
                'as Supabase function secrets.',
            compact: true,
          );
        }
        return Column(
          children: spaced([
            for (final p in providers)
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            aiProviderLabels[p['provider']] ??
                                '${p['provider']}',
                            style: t.titleSmall,
                          ),
                        ),
                        _StatusPill(
                          p['configured'] == true
                              ? (p['circuit'] == 'open'
                                    ? 'circuit open'
                                    : 'configured')
                              : 'not configured',
                          ok: p['configured'] == true && p['circuit'] != 'open',
                        ),
                      ],
                    ),
                    if (p['default_model'] != null)
                      Text(
                        'Default model: ${p['default_model']}',
                        style: t.bodySmall,
                      ),
                    for (final a
                        in (p['aliases'] as List? ?? const []).whereType<Map>())
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Text('Key "${a['alias']}"', style: t.bodySmall),
                            const SizedBox(width: AppSpacing.sm),
                            _StatusPill(
                              '${a['status']}',
                              ok: a['status'] == 'ok',
                            ),
                            if (a['cooldown_until'] != null)
                              Flexible(
                                child: Text(
                                  ' until ${a['cooldown_until']}',
                                  style: t.labelSmall,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (p['configured'] == true)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _testing.contains(p['provider'])
                              ? null
                              : () => _test(p['provider'] as String),
                          icon: const Icon(Icons.network_check, size: 18),
                          label: Text(
                            _testing.contains(p['provider'])
                                ? 'Testing…'
                                : 'Test connection',
                          ),
                        ),
                      ),
                    if (_results[p['provider']] != null)
                      Text(_results[p['provider']]!, style: t.bodySmall),
                  ],
                ),
              ),
          ]),
        );
      },
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill(this.label, {required this.ok});
  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? AppColors.success : AppColors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: AppRadii.chip,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class _UsageSection extends ConsumerWidget {
  const _UsageSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(aiStatusProvider);
    final usage = (status.value?['usage'] as Map?)?.cast<String, Object?>();
    if (usage == null) {
      return status.isLoading
          ? const LoadingState()
          : const EmptyState(
              icon: Icons.query_stats,
              title: 'Usage unavailable',
              compact: true,
            );
    }
    final spend = (usage['cost_usd'] as num?)?.toDouble() ?? 0;
    final budget = (usage['monthly_budget_usd'] as num?)?.toDouble() ?? 0;
    final alerts = (usage['alerts'] as List? ?? const []).join('%, ');
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MetricBar(
            label: 'Spend since ${usage['month_start'] ?? 'month start'}',
            value: spend,
            target: budget,
            color: spend >= budget ? AppColors.danger : AppColors.brand,
            formatter: (v) => '\$${v.toStringAsFixed(2)}',
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.xl,
            runSpacing: AppSpacing.sm,
            children: [
              StatTile(
                label: 'Requests',
                value: Fmt.integer((usage['requests'] as num?) ?? 0),
              ),
              StatTile(
                label: 'Input tokens',
                value: Fmt.integer((usage['input_tokens'] as num?) ?? 0),
              ),
              StatTile(
                label: 'Output tokens',
                value: Fmt.integer((usage['output_tokens'] as num?) ?? 0),
              ),
            ],
          ),
          if (alerts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: NoticeBanner(
                message: 'Budget thresholds reached: $alerts%.',
                color: AppColors.warning,
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _PreferencesSection extends ConsumerStatefulWidget {
  const _PreferencesSection();
  @override
  ConsumerState<_PreferencesSection> createState() =>
      _PreferencesSectionState();
}

class _PreferencesSectionState extends ConsumerState<_PreferencesSection> {
  AiPreferences? _prefs;
  final _model = TextEditingController();
  final _budget = TextEditingController();
  bool _dirty = false;

  @override
  void dispose() {
    _model.dispose();
    _budget.dispose();
    super.dispose();
  }

  void _update(AiPreferences p) => setState(() {
    _prefs = p;
    _dirty = true;
  });

  Future<void> _save() async {
    final p = _prefs;
    if (p == null) return;
    final budget = double.tryParse(_budget.text.trim());
    final next = p.copyWith(
      model: () => _model.text.trim().isEmpty ? null : _model.text.trim(),
      monthlyBudgetUsd: budget?.clamp(0, 1000).toDouble(),
    );
    await ref.read(aiPreferencesRepositoryProvider).save(next);
    ref.invalidate(aiPreferencesProvider);
    if (!mounted) return;
    setState(() => _dirty = false);
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('AI preferences saved')));
  }

  @override
  Widget build(BuildContext context) {
    final loaded = ref.watch(aiPreferencesProvider);
    final t = Theme.of(context).textTheme;
    if (_prefs == null) {
      final v = loaded.value;
      if (v == null) return const LoadingState();
      _prefs = v;
      _model.text = v.model ?? '';
      _budget.text = v.monthlyBudgetUsd.toStringAsFixed(2);
    }
    final p = _prefs!;
    final suggestions =
        aiModelSuggestions[p.primaryProvider] ??
        aiModelSuggestions.values.expand((e) => e).toList();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String?>(
            initialValue: p.primaryProvider,
            decoration: const InputDecoration(labelText: 'Primary provider'),
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text('Server default order'),
              ),
              for (final id in aiProviderIds)
                DropdownMenuItem(value: id, child: Text(aiProviderLabels[id]!)),
            ],
            onChanged: (v) => _update(p.copyWith(primaryProvider: () => v)),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _model,
            decoration: const InputDecoration(
              labelText: 'Model (blank = server default)',
            ),
            onChanged: (_) => setState(() => _dirty = true),
          ),
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              for (final m in suggestions)
                ActionChip(
                  label: Text(m),
                  onPressed: () {
                    _model.text = m;
                    setState(() => _dirty = true);
                  },
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text('Fallback order', style: t.labelLarge),
          for (var i = 0; i < p.fallbackProviders.length; i++)
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${i + 1}. ${aiProviderLabels[p.fallbackProviders[i]]}',
                  ),
                ),
                IconButton(
                  tooltip: 'Move up',
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed: i == 0
                      ? null
                      : () {
                          final l = [...p.fallbackProviders];
                          l.insert(i - 1, l.removeAt(i));
                          _update(p.copyWith(fallbackProviders: l));
                        },
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _update(
                    p.copyWith(
                      fallbackProviders: [...p.fallbackProviders]..removeAt(i),
                    ),
                  ),
                ),
              ],
            ),
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              for (final id in aiProviderIds)
                if (!p.fallbackProviders.contains(id))
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 16),
                    label: Text(aiProviderLabels[id]!),
                    onPressed: () => _update(
                      p.copyWith(
                        fallbackProviders: [...p.fallbackProviders, id],
                      ),
                    ),
                  ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text('Max response tokens: ${p.maxTokens}', style: t.labelLarge),
          Slider(
            value: p.maxTokens.toDouble(),
            min: 256,
            max: 16000,
            divisions: 62,
            label: '${p.maxTokens}',
            onChanged: (v) => _update(
              p.copyWith(maxTokens: ((v / 64).round() * 64).clamp(256, 16000)),
            ),
          ),
          Text('Timeout: ${p.timeoutMs ~/ 1000} s', style: t.labelLarge),
          Slider(
            value: p.timeoutMs.toDouble(),
            min: 5000,
            max: 120000,
            divisions: 23,
            label: '${p.timeoutMs ~/ 1000} s',
            onChanged: (v) => _update(p.copyWith(timeoutMs: v.round())),
          ),
          Text('Retries per request', style: t.labelLarge),
          const SizedBox(height: AppSpacing.xs),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('0')),
              ButtonSegment(value: 1, label: Text('1')),
              ButtonSegment(value: 2, label: Text('2')),
            ],
            selected: {p.maxRetries},
            onSelectionChanged: (s) => _update(p.copyWith(maxRetries: s.first)),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _budget,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Monthly budget (USD)',
              helperText: 'The server also enforces its global budget.',
            ),
            onChanged: (_) => setState(() => _dirty = true),
          ),
          const SizedBox(height: AppSpacing.md),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _dirty ? _save : null,
              child: const Text('Save preferences'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _ConsentSection extends ConsumerWidget {
  const _ConsentSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.read(settingsRepositoryProvider);
    Widget toggle(String key, String title, String subtitle) {
      final value = ref.watch(_consentProvider(key)).value ?? false;
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: Text(subtitle),
        value: value,
        onChanged: (v) => settings.set(key, v),
      );
    }

    return AppCard(
      child: Column(
        children: [
          toggle(
            SettingKeys.aiHealthConsent,
            'Share health data with AI',
            'Food, water, steps, training, mood and targets — only the '
                'minimal tool results a question needs.',
          ),
          toggle(
            SettingKeys.aiJournalConsent,
            'Share journal excerpts with AI',
            'Dates and the first 200 characters of entries. Off by default.',
          ),
          toggle(
            SettingKeys.aiPhotoConsent,
            'Share meal photos with AI',
            'Only when you use photo-based food estimates.',
          ),
          const Padding(
            padding: EdgeInsets.only(top: AppSpacing.sm),
            child: NoticeBanner(
              message:
                  'Strava data is never sent to AI models (Strava API '
                  'policy). Strava runs are analysed on-device only.',
            ),
          ),
        ],
      ),
    );
  }
}

class _CostDisclosure extends StatelessWidget {
  const _CostDisclosure();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Features that incur third-party costs', style: t.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          for (final s in const [
            'AI coach chat — each message (and each tool round) is a paid '
                'call to the selected AI provider, billed to the backend '
                "owner's provider account.",
            'Provider "Test connection" — a tiny paid call per key.',
            'AI food estimates and photo analysis (if enabled) — paid calls.',
            'Supabase — free tier covers personal use; heavy usage may '
                'require a paid plan.',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• $s', style: t.bodySmall),
            ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Everything else (logging, charts, rule-based analysis) runs '
            'on-device for free. Spending stops at your monthly budget.',
            style: t.bodySmall,
          ),
        ],
      ),
    );
  }
}
