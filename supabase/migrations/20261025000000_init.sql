-- =============================================================================
-- Athlete OS - initial schema (Postgres 15 / Supabase)
-- =============================================================================
--
-- Conventions
-- * Every user-owned table mirrors a local Drift table from
--   lib/data/db/tables.dart (camelCase -> snake_case) and adds
--   `user_id uuid not null references auth.users(id) on delete cascade`.
-- * Primary keys are the client-generated text UUIDs used locally, so rows
--   created offline sync idempotently. Single-row / keyed local tables get a
--   user-scoped key instead (user_profiles: user_id; app_settings:
--   (user_id, key); daily_health_summaries: (user_id, local_date, type,
--   origin); integration_connections: (user_id, provider);
--   notification_prefs: (user_id, kind)).
-- * Parent tables expose `unique (user_id, id)` and children reference them
--   with composite foreign keys `(user_id, parent_id)`, so a row can never
--   point at another user's parent even though ids are globally unique.
-- * `local_date` (and other YYYY-MM-DD calendar fields) are `date`; instants
--   are `timestamptz` (UTC on the wire).
-- * Every user table has created_at / updated_at (default now()); updated_at
--   is maintained by the shared set_updated_at() trigger. Tables with local
--   soft delete keep `deleted_at`.
-- * Enumerations documented in tables.dart comments are enforced with CHECK
--   constraints. Extend the constraint in a new migration when the client
--   adds a value.
-- * RLS is enabled on EVERY table. User tables get four policies
--   (select/insert/update/delete) restricted to `user_id = auth.uid()`.
--   Server-only tables (ai_usage, ai_credential_health, ai_circuit_state,
--   ai_response_cache, api_rate_limits) have RLS enabled and NO client
--   policies; edge functions access them with the service role.
-- * strava_tokens lives in its own migration (owned by the Strava slice).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Shared trigger function
-- -----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- =============================================================================
-- Profile, goals, settings
-- =============================================================================

-- Local table is single-row (id = 1); remotely one row per user.
create table public.user_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  height_cm double precision check (height_cm is null or height_cm > 0),
  target_weight_kg double precision check (target_weight_kg is null or target_weight_kg > 0),
  diet_type text not null default 'eggetarian'
    check (diet_type in ('omnivore', 'vegetarian', 'eggetarian', 'vegan', 'pescatarian')),
  restrictions_json text not null default '[]',
  disliked_foods_json text not null default '[]',
  calorie_target integer not null default 2000 check (calorie_target >= 0),
  protein_target_g double precision not null default 150 check (protein_target_g >= 0),
  carbs_target_g double precision not null default 200 check (carbs_target_g >= 0),
  fat_target_g double precision not null default 60 check (fat_target_g >= 0),
  fiber_target_g double precision check (fiber_target_g is null or fiber_target_g >= 0),
  step_goal integer not null default 10000 check (step_goal >= 0),
  water_goal_ml integer not null default 3000 check (water_goal_ml >= 0),
  wake_minutes integer not null default 390 check (wake_minutes between 0 and 1439),
  sleep_minutes integer not null default 1350 check (sleep_minutes between 0 and 1439),
  coaching_style text not null default 'direct'
    check (coaching_style in ('direct', 'encouraging', 'analytical')),
  training_availability text,
  run_goal_distance_m integer not null default 5000 check (run_goal_distance_m > 0),
  run_goal_time_s integer not null default 1800 check (run_goal_time_s > 0),
  fitness_goals text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.goal_history (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  metric text not null,
  old_value text,
  new_value text not null,
  changed_by text not null default 'user' check (changed_by in ('user', 'ai_approved')),
  reason text,
  changed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index goal_history_user_changed_idx on public.goal_history (user_id, changed_at desc);

create table public.app_settings (
  user_id uuid not null references auth.users(id) on delete cascade,
  key text not null,
  value_json text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, key)
);

create table public.health_restrictions (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  description text not null,
  body_part text,
  restriction text,
  clinician_imposed boolean not null default false,
  start_date date,
  end_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_date is null or start_date is null or end_date >= start_date)
);
create index health_restrictions_user_idx on public.health_restrictions (user_id);

-- =============================================================================
-- Nutrition
-- =============================================================================

create table public.foods (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  brand text,
  barcode text,
  serving_size double precision not null default 100 check (serving_size > 0),
  serving_unit text not null default 'g',
  grams_per_serving double precision check (grams_per_serving is null or grams_per_serving > 0),
  calories double precision not null check (calories >= 0),
  protein_g double precision not null default 0 check (protein_g >= 0),
  carbs_g double precision not null default 0 check (carbs_g >= 0),
  fat_g double precision not null default 0 check (fat_g >= 0),
  fiber_g double precision check (fiber_g is null or fiber_g >= 0),
  source text not null
    check (source in ('openfoodfacts', 'usda', 'custom', 'ai_estimate', 'quick_add')),
  source_id text,
  verification text not null
    check (verification in ('verified_label', 'database', 'user_entered', 'estimate')),
  is_favorite boolean not null default false,
  raw_json text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (user_id, id)
);
create index foods_user_name_idx on public.foods (user_id, name);
create index foods_user_barcode_idx on public.foods (user_id, barcode) where barcode is not null;

create table public.recipes (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  servings double precision not null default 1 check (servings > 0),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (user_id, id)
);
create index recipes_user_idx on public.recipes (user_id);

create table public.food_log_entries (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  food_id text,
  recipe_id text, -- no FK locally either (recipe may be deleted later)
  name text not null,
  brand text,
  meal_type text not null check (meal_type in ('breakfast', 'lunch', 'dinner', 'snack')),
  servings double precision not null default 1 check (servings > 0),
  grams double precision check (grams is null or grams > 0),
  calories double precision not null check (calories >= 0),
  protein_g double precision not null default 0 check (protein_g >= 0),
  carbs_g double precision not null default 0 check (carbs_g >= 0),
  fat_g double precision not null default 0 check (fat_g >= 0),
  fiber_g double precision check (fiber_g is null or fiber_g >= 0),
  source text not null,
  verification text not null,
  logged_at timestamptz not null,
  local_date date not null,
  tz_name text not null,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  foreign key (user_id, food_id) references public.foods (user_id, id)
);
create index food_log_entries_user_date_idx on public.food_log_entries (user_id, local_date);
create index food_log_entries_food_idx on public.food_log_entries (user_id, food_id) where food_id is not null;

create table public.recipe_ingredients (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  recipe_id text not null,
  food_id text,
  name text not null,
  servings double precision not null default 1 check (servings > 0),
  grams double precision check (grams is null or grams > 0),
  calories double precision not null check (calories >= 0),
  protein_g double precision not null default 0 check (protein_g >= 0),
  carbs_g double precision not null default 0 check (carbs_g >= 0),
  fat_g double precision not null default 0 check (fat_g >= 0),
  fiber_g double precision check (fiber_g is null or fiber_g >= 0),
  verification text not null default 'user_entered',
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (user_id, recipe_id) references public.recipes (user_id, id) on delete cascade,
  foreign key (user_id, food_id) references public.foods (user_id, id)
);
create index recipe_ingredients_recipe_idx on public.recipe_ingredients (user_id, recipe_id, position);
create index recipe_ingredients_food_idx on public.recipe_ingredients (user_id, food_id) where food_id is not null;

create table public.saved_meals (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  meal_type text check (meal_type is null or meal_type in ('breakfast', 'lunch', 'dinner', 'snack')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (user_id, id)
);
create index saved_meals_user_idx on public.saved_meals (user_id);

create table public.saved_meal_items (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  saved_meal_id text not null,
  food_id text,
  name text not null,
  servings double precision not null default 1 check (servings > 0),
  grams double precision check (grams is null or grams > 0),
  calories double precision not null check (calories >= 0),
  protein_g double precision not null default 0 check (protein_g >= 0),
  carbs_g double precision not null default 0 check (carbs_g >= 0),
  fat_g double precision not null default 0 check (fat_g >= 0),
  fiber_g double precision check (fiber_g is null or fiber_g >= 0),
  verification text not null,
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (user_id, saved_meal_id) references public.saved_meals (user_id, id) on delete cascade,
  foreign key (user_id, food_id) references public.foods (user_id, id)
);
create index saved_meal_items_meal_idx on public.saved_meal_items (user_id, saved_meal_id, position);
create index saved_meal_items_food_idx on public.saved_meal_items (user_id, food_id) where food_id is not null;

-- =============================================================================
-- Hydration
-- =============================================================================

create table public.water_logs (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  amount_ml integer not null check (amount_ml between 1 and 5000),
  logged_at timestamptz not null,
  local_date date not null,
  source text not null default 'manual' check (source in ('manual', 'notification', 'ai')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index water_logs_user_date_idx on public.water_logs (user_id, local_date);

-- =============================================================================
-- Health data (Health Connect / manual)
-- =============================================================================

create table public.health_samples (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  type text not null check (type in (
    'heart_rate', 'resting_heart_rate', 'weight', 'sleep_session',
    'exercise_session', 'active_kcal', 'total_kcal')),
  value double precision not null,
  unit text not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  local_date date not null,
  source_app text,
  source_device text not null default 'unknown'
    check (source_device in ('watch', 'phone', 'scale', 'manual', 'unknown')),
  origin text not null check (origin in ('health_connect', 'manual')),
  external_id text,
  metadata_json text,
  synced_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_at >= start_at),
  unique (user_id, origin, type, external_id)
);
create index health_samples_user_date_idx on public.health_samples (user_id, local_date, type);

create table public.daily_health_summaries (
  user_id uuid not null references auth.users(id) on delete cascade,
  local_date date not null,
  type text not null
    check (type in ('steps', 'distance_m', 'active_minutes', 'active_kcal', 'sleep_minutes')),
  value double precision not null,
  unit text not null,
  origin text not null check (origin in ('health_connect', 'manual')),
  sources_summary text,
  computed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, local_date, type, origin)
);

-- =============================================================================
-- Training and cardio
-- =============================================================================

create table public.workouts (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  source text not null check (source in ('hevy', 'manual', 'csv', 'health_connect')),
  external_id text,
  title text not null,
  start_at timestamptz not null,
  end_at timestamptz,
  local_date date not null,
  notes text,
  raw_json text,
  source_updated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (end_at is null or end_at >= start_at),
  unique (user_id, id),
  unique (user_id, source, external_id)
);
create index workouts_user_date_idx on public.workouts (user_id, local_date);

create table public.workout_exercises (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  workout_id text not null,
  position integer not null,
  name text not null,
  template_id text,
  muscle_group text,
  notes text,
  superset_id integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, id),
  foreign key (user_id, workout_id) references public.workouts (user_id, id) on delete cascade
);
create index workout_exercises_workout_idx on public.workout_exercises (user_id, workout_id, position);

create table public.workout_sets (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  exercise_id text not null,
  position integer not null,
  set_type text not null default 'normal'
    check (set_type in ('normal', 'warmup', 'dropset', 'failure')),
  weight_kg double precision check (weight_kg is null or weight_kg >= 0),
  reps integer check (reps is null or reps >= 0),
  distance_m double precision check (distance_m is null or distance_m >= 0),
  duration_s integer check (duration_s is null or duration_s >= 0),
  rpe double precision check (rpe is null or rpe between 0 and 10),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (user_id, exercise_id) references public.workout_exercises (user_id, id) on delete cascade
);
create index workout_sets_exercise_idx on public.workout_sets (user_id, exercise_id, position);

-- NOTE: rows with source = 'strava' must never be sent to an AI provider
-- (Strava API Policy) and must be refreshed or purged within 7 days.
create table public.cardio_activities (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  source text not null check (source in ('strava', 'health_connect', 'manual')),
  external_id text,
  name text,
  sport_type text not null check (sport_type in ('run', 'walk', 'ride', 'hike', 'other')),
  start_at timestamptz not null,
  local_date date not null,
  tz_name text,
  distance_m double precision check (distance_m is null or distance_m >= 0),
  moving_time_s integer check (moving_time_s is null or moving_time_s >= 0),
  elapsed_time_s integer check (elapsed_time_s is null or elapsed_time_s >= 0),
  elevation_gain_m double precision,
  avg_heart_rate double precision check (avg_heart_rate is null or avg_heart_rate > 0),
  max_heart_rate double precision check (max_heart_rate is null or max_heart_rate > 0),
  avg_speed_mps double precision check (avg_speed_mps is null or avg_speed_mps >= 0),
  calories double precision check (calories is null or calories >= 0),
  splits_json text,
  laps_json text,
  raw_json text,
  fetched_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (user_id, source, external_id)
);
create index cardio_activities_user_date_idx on public.cardio_activities (user_id, local_date);
create index cardio_activities_strava_fetched_idx on public.cardio_activities (fetched_at)
  where source = 'strava';

-- =============================================================================
-- Well-being, habits, planning
-- =============================================================================

create table public.mood_entries (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  local_date date not null,
  recorded_at timestamptz not null,
  mood integer not null check (mood between 1 and 5),
  energy integer check (energy is null or energy between 1 and 5),
  stress integer check (stress is null or stress between 1 and 5),
  sleep_quality integer check (sleep_quality is null or sleep_quality between 1 and 5),
  emotion_tags_json text not null default '[]',
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index mood_entries_user_date_idx on public.mood_entries (user_id, local_date);

create table public.journal_entries (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  local_date date not null,
  body text not null default '',
  gratitude text,
  prompt text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index journal_entries_user_date_idx on public.journal_entries (user_id, local_date);

create table public.habits (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  category text not null default 'other'
    check (category in ('health', 'fitness', 'nutrition', 'mind', 'productivity', 'other')),
  schedule_type text not null default 'daily' check (schedule_type in ('daily', 'weekly', 'custom')),
  days_mask integer not null default 127 check (days_mask between 0 and 127),
  target_per_week integer check (target_per_week is null or target_per_week between 1 and 7),
  reminder_times_json text not null default '[]',
  notes text,
  depends_on_habit_id text, -- no FK locally either
  auto_rule text check (auto_rule is null or auto_rule in ('water_goal', 'step_goal', 'food_logged')),
  archived boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (user_id, id)
);
create index habits_user_idx on public.habits (user_id, sort_order);

create table public.habit_completions (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  habit_id text not null,
  local_date date not null,
  status text not null default 'done' check (status in ('done', 'skipped')),
  completed_at timestamptz not null default now(),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (habit_id, local_date),
  foreign key (user_id, habit_id) references public.habits (user_id, id) on delete cascade
);
create index habit_completions_user_date_idx on public.habit_completions (user_id, local_date);

create table public.tasks (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  local_date date not null,
  priority integer not null default 2 check (priority >= 1),
  done boolean not null default false,
  completed_at timestamptz,
  carried_from_date date,
  project text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index tasks_user_date_idx on public.tasks (user_id, local_date);

create table public.calendar_event_refs (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  calendar_id text not null,
  event_id text not null,
  kind text not null check (kind in ('workout', 'meal_prep', 'focus', 'habit', 'other')),
  start_at timestamptz not null,
  end_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_at >= start_at)
);
create index calendar_event_refs_user_start_idx on public.calendar_event_refs (user_id, start_at);

-- =============================================================================
-- Competition prep
-- =============================================================================

create table public.competitions (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  event_date date not null,
  tz_name text not null,
  location text,
  division text,
  notes text,
  is_primary boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (user_id, id)
);
create index competitions_user_date_idx on public.competitions (user_id, event_date);

create table public.competition_milestones (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  competition_id text not null,
  title text not null,
  kind text not null default 'milestone' check (kind in ('milestone', 'checklist')),
  due_date date,
  done boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (user_id, competition_id) references public.competitions (user_id, id) on delete cascade
);
create index competition_milestones_comp_idx on public.competition_milestones (user_id, competition_id, sort_order);

-- Photos themselves stay on-device; only metadata is mirrored (local_path is
-- meaningful on the originating device only).
create table public.progress_photos (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  local_path text not null,
  taken_at timestamptz not null,
  local_date date not null,
  pose text,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index progress_photos_user_date_idx on public.progress_photos (user_id, local_date);

-- =============================================================================
-- AI agent (client-visible)
-- =============================================================================

create table public.ai_conversations (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  title text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, id)
);
create index ai_conversations_user_idx on public.ai_conversations (user_id, updated_at desc);

create table public.ai_messages (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  conversation_id text not null,
  role text not null check (role in ('user', 'assistant', 'tool')),
  content_json text not null,
  provider text,
  model text,
  input_tokens integer check (input_tokens is null or input_tokens >= 0),
  output_tokens integer check (output_tokens is null or output_tokens >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (user_id, conversation_id) references public.ai_conversations (user_id, id) on delete cascade
);
create index ai_messages_conversation_idx on public.ai_messages (user_id, conversation_id, created_at);

create table public.ai_tool_actions (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  conversation_id text,
  tool_name text not null,
  args_json text not null,
  result_summary text,
  status text not null
    check (status in ('ok', 'error', 'rejected', 'pending_confirmation', 'confirmed')),
  is_write boolean not null default false,
  idempotency_key text not null,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, idempotency_key)
);
create index ai_tool_actions_user_created_idx on public.ai_tool_actions (user_id, created_at desc);

create table public.ai_memories (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null check (category in ('preference', 'goal', 'routine', 'context')),
  content text not null,
  origin text not null default 'user' check (origin in ('user', 'ai_suggested')),
  approved boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index ai_memories_user_idx on public.ai_memories (user_id, category);

create table public.ai_recommendations (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('habit', 'nutrition', 'training', 'schedule', 'general')),
  content text not null,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'edited', 'dismissed')),
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index ai_recommendations_user_idx on public.ai_recommendations (user_id, created_at desc);

-- =============================================================================
-- Integrations, sync, notifications, reports
-- =============================================================================

create table public.integration_connections (
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null check (provider in (
    'health_connect', 'hevy', 'strava', 'google_calendar', 'open_food_facts',
    'usda', 'ai_backend')),
  status text not null check (status in (
    'connected', 'disconnected', 'needs_setup', 'error', 'awaiting_credentials')),
  scopes_json text not null default '[]',
  connected_at timestamptz,
  last_sync_at timestamptz,
  last_attempt_at timestamptz,
  last_error text,
  cursor text,
  meta_json text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, provider)
);

create table public.sync_queue (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  entity_table text not null,
  entity_id text not null,
  op text not null check (op in ('upsert', 'delete')),
  payload_json text not null,
  idempotency_key text not null,
  attempts integer not null default 0 check (attempts >= 0),
  last_error text,
  next_attempt_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, idempotency_key)
);
create index sync_queue_user_next_idx on public.sync_queue (user_id, next_attempt_at);

create table public.notification_prefs (
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in (
    'water', 'habit', 'planning', 'mood', 'meal', 'steps', 'workout',
    'competition', 'eod_review', 'weekly_summary')),
  enabled boolean not null default false,
  config_json text not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, kind)
);

create table public.reports (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('weekly', 'monthly')),
  period_start date not null,
  period_end date not null,
  content_json text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (period_end >= period_start)
);
create index reports_user_period_idx on public.reports (user_id, kind, period_start desc);

-- =============================================================================
-- AI backend settings (user-editable)
-- =============================================================================

create table public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  primary_provider text check (primary_provider is null or primary_provider in ('anthropic', 'openai', 'gemini')),
  model text check (model is null or char_length(model) <= 100),
  fallback_providers text[] not null default '{}'
    check (fallback_providers <@ array['anthropic', 'openai', 'gemini']::text[]),
  max_tokens integer check (max_tokens is null or max_tokens between 256 and 16000),
  timeout_ms integer check (timeout_ms is null or timeout_ms between 5000 and 120000),
  monthly_budget_usd numeric(10, 2) check (monthly_budget_usd is null or monthly_budget_usd >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- =============================================================================
-- Server-only tables (service role; RLS on, no client policies)
-- =============================================================================

-- One row per AI request (request_id is the client idempotency key).
create table public.ai_usage (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  request_id text not null unique,
  provider text,
  model text,
  credential_alias text,
  input_tokens integer not null default 0 check (input_tokens >= 0),
  output_tokens integer not null default 0 check (output_tokens >= 0),
  cost_usd numeric(12, 6) not null default 0 check (cost_usd >= 0),
  status text not null check (status in ('ok', 'error', 'cached', 'refused')),
  latency_ms integer check (latency_ms is null or latency_ms >= 0),
  created_at timestamptz not null default now()
);
create index ai_usage_user_created_idx on public.ai_usage (user_id, created_at);
create index ai_usage_created_idx on public.ai_usage (created_at);

-- Health of each configured provider credential (keys themselves live only
-- in function secrets). last_error is always redacted before it is written.
create table public.ai_credential_health (
  provider text not null check (provider in ('anthropic', 'openai', 'gemini')),
  alias text not null check (alias in ('primary', 'secondary')),
  status text not null default 'ok'
    check (status in ('ok', 'rate_limited', 'quota_exhausted', 'invalid', 'disabled')),
  cooldown_until timestamptz,
  consecutive_failures integer not null default 0 check (consecutive_failures >= 0),
  last_error text,
  updated_at timestamptz not null default now(),
  primary key (provider, alias)
);

-- Per-provider circuit breaker shared between function isolates.
create table public.ai_circuit_state (
  provider text primary key check (provider in ('anthropic', 'openai', 'gemini')),
  state text not null default 'closed' check (state in ('closed', 'open', 'half_open')),
  consecutive_failures integer not null default 0 check (consecutive_failures >= 0),
  opened_at timestamptz,
  updated_at timestamptz not null default now()
);

-- Idempotent replay cache for ai-chat. TTL 24 h: rows older than that are
-- ignored by the function and removed by purge_ai_response_cache()
-- (schedule it with pg_cron, e.g. hourly).
create table public.ai_response_cache (
  request_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  response jsonb not null,
  created_at timestamptz not null default now()
);
create index ai_response_cache_created_idx on public.ai_response_cache (created_at);
comment on table public.ai_response_cache is
  'ai-chat idempotency cache keyed by client request_id. TTL 24h; purge with purge_ai_response_cache().';

-- Fixed-window rate limiting counters.
create table public.api_rate_limits (
  user_id uuid not null references auth.users(id) on delete cascade,
  bucket text not null,
  window_start timestamptz not null,
  count integer not null default 0 check (count >= 0),
  primary key (user_id, bucket, window_start)
);
create index api_rate_limits_window_idx on public.api_rate_limits (window_start);

-- =============================================================================
-- Server-side functions (service_role only)
-- =============================================================================

create or replace function public.purge_ai_response_cache()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  n integer;
begin
  delete from public.ai_response_cache where created_at < now() - interval '24 hours';
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.purge_api_rate_limits()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  n integer;
begin
  delete from public.api_rate_limits where window_start < now() - interval '1 hour';
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Atomic upsert-increment; returns the counter value after this request.
create or replace function public.increment_rate_limit(
  p_user uuid,
  p_bucket text,
  p_window_start timestamptz
)
returns integer
language sql
security definer
set search_path = ''
as $$
  insert into public.api_rate_limits as r (user_id, bucket, window_start, count)
  values (p_user, p_bucket, p_window_start, 1)
  on conflict (user_id, bucket, window_start)
  do update set count = r.count + 1
  returning r.count;
$$;

-- Month-to-date spend for one user.
create or replace function public.ai_month_spend(p_user uuid, p_month_start timestamptz)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(u.cost_usd), 0)::numeric
  from public.ai_usage u
  where u.user_id = p_user and u.created_at >= p_month_start;
$$;

-- Month-to-date spend across all users (global budget guard).
create or replace function public.ai_global_month_spend(p_month_start timestamptz)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(u.cost_usd), 0)::numeric
  from public.ai_usage u
  where u.created_at >= p_month_start;
$$;

-- Month-to-date usage summary for ai-status (refused requests excluded).
create or replace function public.ai_month_usage(p_user uuid, p_month_start timestamptz)
returns table (requests bigint, input_tokens bigint, output_tokens bigint, cost_usd numeric)
language sql
stable
security definer
set search_path = ''
as $$
  select
    count(*)::bigint,
    coalesce(sum(u.input_tokens), 0)::bigint,
    coalesce(sum(u.output_tokens), 0)::bigint,
    coalesce(sum(u.cost_usd), 0)::numeric
  from public.ai_usage u
  where u.user_id = p_user
    and u.created_at >= p_month_start
    and u.status <> 'refused';
$$;

revoke execute on function public.purge_ai_response_cache() from public, anon, authenticated;
revoke execute on function public.purge_api_rate_limits() from public, anon, authenticated;
revoke execute on function public.increment_rate_limit(uuid, text, timestamptz) from public, anon, authenticated;
revoke execute on function public.ai_month_spend(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.ai_global_month_spend(timestamptz) from public, anon, authenticated;
revoke execute on function public.ai_month_usage(uuid, timestamptz) from public, anon, authenticated;

grant execute on function public.purge_ai_response_cache() to service_role;
grant execute on function public.purge_api_rate_limits() to service_role;
grant execute on function public.increment_rate_limit(uuid, text, timestamptz) to service_role;
grant execute on function public.ai_month_spend(uuid, timestamptz) to service_role;
grant execute on function public.ai_global_month_spend(timestamptz) to service_role;
grant execute on function public.ai_month_usage(uuid, timestamptz) to service_role;

-- =============================================================================
-- updated_at triggers
-- =============================================================================
do $$
declare
  t text;
begin
  foreach t in array array[
    'user_profiles', 'goal_history', 'app_settings', 'health_restrictions',
    'foods', 'recipes', 'food_log_entries', 'recipe_ingredients',
    'saved_meals', 'saved_meal_items', 'water_logs', 'health_samples',
    'daily_health_summaries', 'workouts', 'workout_exercises', 'workout_sets',
    'cardio_activities', 'mood_entries', 'journal_entries', 'habits',
    'habit_completions', 'tasks', 'calendar_event_refs', 'competitions',
    'competition_milestones', 'progress_photos', 'ai_conversations',
    'ai_messages', 'ai_tool_actions', 'ai_memories', 'ai_recommendations',
    'integration_connections', 'sync_queue', 'notification_prefs', 'reports',
    'user_settings', 'ai_credential_health', 'ai_circuit_state'
  ]
  loop
    execute format(
      'create trigger set_updated_at before update on public.%I '
      'for each row execute function public.set_updated_at()', t);
  end loop;
end;
$$;

-- =============================================================================
-- Row level security
-- =============================================================================

-- User-owned tables: owner-only access for the authenticated role.
do $$
declare
  t text;
begin
  foreach t in array array[
    'user_profiles', 'goal_history', 'app_settings', 'health_restrictions',
    'foods', 'recipes', 'food_log_entries', 'recipe_ingredients',
    'saved_meals', 'saved_meal_items', 'water_logs', 'health_samples',
    'daily_health_summaries', 'workouts', 'workout_exercises', 'workout_sets',
    'cardio_activities', 'mood_entries', 'journal_entries', 'habits',
    'habit_completions', 'tasks', 'calendar_event_refs', 'competitions',
    'competition_milestones', 'progress_photos', 'ai_conversations',
    'ai_messages', 'ai_tool_actions', 'ai_memories', 'ai_recommendations',
    'integration_connections', 'sync_queue', 'notification_prefs', 'reports',
    'user_settings'
  ]
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for select to authenticated '
      'using (user_id = (select auth.uid()))', t || '_select_own', t);
    execute format(
      'create policy %I on public.%I for insert to authenticated '
      'with check (user_id = (select auth.uid()))', t || '_insert_own', t);
    execute format(
      'create policy %I on public.%I for update to authenticated '
      'using (user_id = (select auth.uid())) '
      'with check (user_id = (select auth.uid()))', t || '_update_own', t);
    execute format(
      'create policy %I on public.%I for delete to authenticated '
      'using (user_id = (select auth.uid()))', t || '_delete_own', t);
  end loop;
end;
$$;

-- Server-only tables: RLS on, no policies, and no table privileges for
-- client roles (defence in depth). The service role bypasses RLS.
do $$
declare
  t text;
begin
  foreach t in array array[
    'ai_usage', 'ai_credential_health', 'ai_circuit_state',
    'ai_response_cache', 'api_rate_limits'
  ]
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
    execute format('grant all on table public.%I to service_role', t);
  end loop;
end;
$$;

revoke all on sequence public.ai_usage_id_seq from anon, authenticated;
grant usage, select on sequence public.ai_usage_id_seq to service_role;
