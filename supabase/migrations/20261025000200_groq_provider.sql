-- Adds Groq as an AI provider id (OpenAI-compatible Chat Completions adapter).
-- Only CHECK constraints change; RLS and policies are untouched.

alter table public.user_settings
  drop constraint if exists user_settings_primary_provider_check,
  add constraint user_settings_primary_provider_check
    check (primary_provider is null or primary_provider in ('anthropic', 'openai', 'gemini', 'groq'));

alter table public.user_settings
  drop constraint if exists user_settings_fallback_providers_check,
  add constraint user_settings_fallback_providers_check
    check (fallback_providers <@ array['anthropic', 'openai', 'gemini', 'groq']::text[]);

alter table public.ai_credential_health
  drop constraint if exists ai_credential_health_provider_check,
  add constraint ai_credential_health_provider_check
    check (provider in ('anthropic', 'openai', 'gemini', 'groq'));

alter table public.ai_circuit_state
  drop constraint if exists ai_circuit_state_provider_check,
  add constraint ai_circuit_state_provider_check
    check (provider in ('anthropic', 'openai', 'gemini', 'groq'));
