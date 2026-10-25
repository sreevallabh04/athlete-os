import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/settings_repository.dart';

/// Provider ids understood by the `ai-chat` edge function.
const aiProviderIds = ['anthropic', 'openai', 'gemini'];

const aiProviderLabels = {
  'anthropic': 'Anthropic Claude',
  'openai': 'OpenAI',
  'gemini': 'Google Gemini',
};

/// Model suggestions shown in settings. The server's allowlist is the source
/// of truth (see `ai-status`); these are only hints.
const aiModelSuggestions = {
  'anthropic': ['claude-sonnet-5-5', 'claude-haiku-5-5', 'claude-opus-5-5'],
  'openai': ['gpt-5.4-mini'],
  'gemini': ['gemini-3.8-flash'],
};

/// User preferences sent with every AI request. Stored locally in
/// `app_settings` under keys prefixed `ai.`; the server clamps every value to
/// its own allowlists and limits.
class AiPreferences {
  const AiPreferences({
    this.primaryProvider,
    this.model,
    this.fallbackProviders = const ['openai', 'gemini'],
    this.maxTokens = 4096,
    this.timeoutMs = 60000,
    this.maxRetries = 2,
    this.monthlyBudgetUsd = 10,
  });

  /// Null = server default order (`AI_PROVIDER_ORDER`).
  final String? primaryProvider;

  /// Null = the server's default model for the chosen provider.
  final String? model;
  final List<String> fallbackProviders;
  final int maxTokens;
  final int timeoutMs;
  final int maxRetries;
  final double monthlyBudgetUsd;

  AiPreferences copyWith({
    String? Function()? primaryProvider,
    String? Function()? model,
    List<String>? fallbackProviders,
    int? maxTokens,
    int? timeoutMs,
    int? maxRetries,
    double? monthlyBudgetUsd,
  }) => AiPreferences(
    primaryProvider: primaryProvider != null
        ? primaryProvider()
        : this.primaryProvider,
    model: model != null ? model() : this.model,
    fallbackProviders: fallbackProviders ?? this.fallbackProviders,
    maxTokens: maxTokens ?? this.maxTokens,
    timeoutMs: timeoutMs ?? this.timeoutMs,
    maxRetries: maxRetries ?? this.maxRetries,
    monthlyBudgetUsd: monthlyBudgetUsd ?? this.monthlyBudgetUsd,
  );

  Map<String, Object?> toWire() => {
    'primary_provider': primaryProvider,
    'model': (model?.trim().isEmpty ?? true) ? null : model!.trim(),
    'fallback_providers': fallbackProviders,
    'max_tokens': maxTokens,
    'timeout_ms': timeoutMs,
    'max_retries': maxRetries,
    'monthly_budget_usd': monthlyBudgetUsd,
  };
}

abstract final class AiSettingKeys {
  static const primaryProvider = 'ai.primary_provider';
  static const model = 'ai.model';
  static const fallbackProviders = 'ai.fallback_providers';
  static const maxTokens = 'ai.max_tokens';
  static const timeoutMs = 'ai.timeout_ms';
  static const maxRetries = 'ai.max_retries';
  static const monthlyBudgetUsd = 'ai.monthly_budget_usd';
}

class AiPreferencesRepository {
  AiPreferencesRepository(this._settings);
  final SettingsRepository _settings;

  Future<AiPreferences> load() async {
    const d = AiPreferences();
    final primary = await _settings.get<String>(AiSettingKeys.primaryProvider);
    final fallback = await _settings.get<List<dynamic>>(
      AiSettingKeys.fallbackProviders,
    );
    return AiPreferences(
      primaryProvider: aiProviderIds.contains(primary) ? primary : null,
      model: await _settings.get<String>(AiSettingKeys.model),
      fallbackProviders: fallback == null
          ? d.fallbackProviders
          : fallback
                .map((e) => e.toString())
                .where(aiProviderIds.contains)
                .toList(),
      maxTokens:
          ((await _settings.get<num>(AiSettingKeys.maxTokens)) ?? d.maxTokens)
              .toInt()
              .clamp(256, 16000),
      timeoutMs:
          ((await _settings.get<num>(AiSettingKeys.timeoutMs)) ?? d.timeoutMs)
              .toInt()
              .clamp(5000, 120000),
      maxRetries:
          ((await _settings.get<num>(AiSettingKeys.maxRetries)) ?? d.maxRetries)
              .toInt()
              .clamp(0, 2),
      monthlyBudgetUsd:
          ((await _settings.get<num>(AiSettingKeys.monthlyBudgetUsd)) ??
                  d.monthlyBudgetUsd)
              .toDouble()
              .clamp(0, 1000),
    );
  }

  Future<void> save(AiPreferences p) async {
    await _settings.set(AiSettingKeys.primaryProvider, p.primaryProvider);
    await _settings.set(AiSettingKeys.model, p.model);
    await _settings.set(AiSettingKeys.fallbackProviders, p.fallbackProviders);
    await _settings.set(AiSettingKeys.maxTokens, p.maxTokens);
    await _settings.set(AiSettingKeys.timeoutMs, p.timeoutMs);
    await _settings.set(AiSettingKeys.maxRetries, p.maxRetries);
    await _settings.set(AiSettingKeys.monthlyBudgetUsd, p.monthlyBudgetUsd);
  }
}

final aiPreferencesRepositoryProvider = Provider<AiPreferencesRepository>(
  (ref) => AiPreferencesRepository(ref.watch(settingsRepositoryProvider)),
);

final aiPreferencesProvider = FutureProvider<AiPreferences>(
  (ref) => ref.watch(aiPreferencesRepositoryProvider).load(),
);
