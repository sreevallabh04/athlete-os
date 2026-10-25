# Health Connect integration

Athlete OS reads health data that Samsung Health (phone + Galaxy Watch)
writes to Android **Health Connect**. The integration is **read-only**,
**foreground-only**, and stores everything locally in the Drift database.

## Architecture

```
lib/features/health/
  domain/        pure Dart, unit tested
    health_types.dart   HcDataType, HealthGroup (permission groups), HcSdkStatus, HcRecord, HealthKeys
    steps_math.dart     goal/remaining/%, waking window, steps per remaining hour, behind-pace, stats, HC-vs-manual precedence
    aggregation.dart    dedupe + merge rules (see below), sleep-night assignment, HR downsampling, sport normalisation
    sources.dart        package name → app label, device type from metadata
  data/
    health_data_source.dart          HealthDataSource interface (gateway)
    health_connect_data_source.dart  implementation over the `health` plugin 13.3.2
    fake_health_data_source.dart     in-memory fake for tests
    health_repository.dart           Drift reads/writes (DailyHealthSummaries, HealthSamples, CardioActivities)
    health_settings.dart             enabled groups in AppSettings (`health.enabled_groups`, `health.history_opt_in`)
  application/
    health_sync_service.dart  HealthSyncService (idempotent, concurrency-guarded)
    health_permissions.dart   HealthPermissionController (enable/disable groups, history)
    health_providers.dart     Riverpod providers (see "Providers for other features")
  presentation/  StepsScreen (/steps), HealthOverviewScreen (/health), HealthStatusScreen (/integrations/health)
  bootstrap.dart healthBootstrap: configure plugin, non-blocking start-up sync, resume listener
```

The plugin is only touched in `HealthConnectDataSource`. Every status or
permission call there is wrapped so it never throws; read calls may throw and
the sync service records the failure per data type.

## Data types and permissions

The user enables **groups**; we request READ access only for the types in
the groups they turn on, after an explanation bottom sheet is shown.

| Group    | Health Connect permission(s)                                                                   | Stored as |
|----------|------------------------------------------------------------------------------------------------|-----------|
| Activity | READ_STEPS, READ_DISTANCE, READ_ACTIVE_CALORIES_BURNED, READ_TOTAL_CALORIES_BURNED, READ_EXERCISE | `DailyHealthSummaries` steps / distance_m / active_kcal / active_minutes; `HealthSamples` exercise_session; `CardioActivities` (run/walk/hike/ride) |
| Heart    | READ_HEART_RATE, READ_RESTING_HEART_RATE                                                        | `HealthSamples` heart_rate (≤1 per 5 min, last 48 h), resting_heart_rate |
| Sleep    | READ_SLEEP                                                                                     | `HealthSamples` sleep_session; `DailyHealthSummaries` sleep_minutes |
| Body     | READ_WEIGHT                                                                                    | `HealthSamples` weight |
| History (optional) | READ_HEALTH_DATA_HISTORY                                                            | — (lets reads go further back than 30 days before first grant) |

READ_TOTAL_CALORIES_BURNED is part of Activity because the plugin enriches
exercise sessions with distance, total calories and steps read inside each
session window; without those permissions the exercise read fails.

All permissions are declared in `android/app/src/main/AndroidManifest.xml`
together with the `ACTION_SHOW_PERMISSIONS_RATIONALE` intent filter and the
`ViewPermissionUsageActivity` alias that Health Connect requires.

Permissions are re-checked on **every** sync (`hasPermissions` per type). A
revoked permission moves the integration status to `needs_setup` with an
explanatory error, and the UI shows "permission not granted" — previously
synced data is kept and labelled with its sync time.

## Samsung Health path and restrictions

* Samsung Health 6.22.5+ writes Steps, ExerciseSession (+distance, speed, HR,
  calories), HeartRate, SleepSession (with stages), Weight, BodyFat… to
  Health Connect. The user must enable it: Samsung Health › ⋮ › Settings ›
  Health Connect.
* Galaxy Watch data goes watch → Samsung Health (phone) → Health Connect.
  Continuous watch heart rate arrives in batches, so it can lag.
* There is no unrestricted direct Samsung Health API for third parties: the
  Samsung Health Data SDK requires partner approval. Health Connect is the
  supported path.
* On Android 14+ Health Connect is part of the OS (Settings › Security &
  privacy › Privacy › Health Connect). Android 9–13 need the Health Connect
  app; the status screen offers Install/Update via `installHealthConnect()`.

## History limit and background reads

* Without READ_HEALTH_DATA_HISTORY, Health Connect only returns data from up
  to **30 days before the first permission grant**. History access is
  optional and requested separately from the status screen.
* We do **not** request READ_HEALTH_DATA_IN_BACKGROUND. Sync runs only in the
  foreground: app start (non-blocking), app resume (throttled to ≥5 min),
  pull-to-refresh, the Sync button, and right after a group is enabled.
  The UI always shows "last synced X ago" and never claims live data.

## Sync

* Window: 30 days on first sync, 7 days afterwards (manual/permission-change
  syncs may force 30). Heart rate: last 48 h.
* Idempotent: Health Connect rows are written as window replacements
  (delete Health Connect rows of that type in the window, then insert) with
  stable ids (`stableId('hc:<type>', <HC uuid>)`). Cardio uses
  `insertOnConflictUpdate` keyed by `stableId('cardio:health_connect', uuid)`
  with unique `(source, externalId = HC uuid)`; soft-deleted cardio rows are
  never resurrected. Manual rows are never touched by sync.
* One sync at a time: concurrent callers share the in-flight future.
* Status: `IntegrationStatusRepository` (`health_connect`) — `connected`
  only after a successful sync; partial failures are listed in
  `metaJson.warnings`; a full failure sets `error` + redacted `lastError`.

## Dedupe rules

1. Records are de-duplicated by Health Connect uuid.
2. **Steps** use the aggregate API (`getTotalStepsInInterval`) per local day,
   so Health Connect's own app-priority dedupe handles phone + watch overlap.
   A past day with a total of 0 is treated as "no data" and not stored.
   `sourcesSummary` lists contributing apps (last 7 days, from raw records).
3. **Distance, active calories**: per local day only ONE source app is used —
   the app with the largest total that day; other apps are listed as "also
   seen, not added". Within that app overlapping records are pro-rated so
   overlapping time counts once. (The plugin's interval-aggregate call is
   avoided: in 13.3.2 the Dart side sends the interval as a 32-bit int while
   the Kotlin side reads it as `Long`, which risks a ClassCastException, and
   `getHealthAggregateDataFromTypes` sends `dataTypeKeys` while the Kotlin
   handler reads `dataTypeKey`. Unverified on device — revisit on upgrade.)
4. **Sleep**: a session belongs to the local date it **ends** on. Per night,
   one source app (most sleep) is used and its overlapping sessions are
   merged. Value = time in sleep sessions (not stage-adjusted).
5. **Active minutes**: union of all exercise-session intervals (any app),
   split at local midnight.
6. **Heart rate**: at most one stored reading per 5-minute bucket — the
   latest actual reading from the app with the most readings in that bucket
   (bucket count/min/max kept in metadata). Nothing is averaged or invented.
7. **Manual vs Health Connect steps**: if both exist for a day, the Health
   Connect value is shown and the manual value is shown as overridden.

Device type (watch/phone/scale) is shown only if record metadata exposes it;
the `health` plugin 13.3.2 does not forward `Metadata.device` on Android, so
it is usually "Device unknown". We never infer the device from the app name.

## Providers for other features

* `todayStepsProvider` → `DaySteps?` (steps, origin, overriddenManual, sources)
* `stepsHistoryProvider(days)` → `Map<localDate, DaySteps?>`
* `healthConnectionProvider` → integration status row (last sync / error)
* `healthSyncServiceProvider` → `sync()` / `syncIfStale()`
* `healthRepositoryProvider` → `stepsForDay`, `setManualSteps`, `addManualWeight`
* Pure functions in `domain/steps_math.dart`: `stepsProgress`,
  `stepsPerRemainingHour`, `checkPace` (behind if steps < 70% of goal ×
  elapsed waking fraction; never before wake, after bedtime, in the first
  waking hour, or once the goal is met).

## Opening Health Connect settings

`HealthConnectDataSource.openSettings()` calls the optional method channel
`athlete_os/health_connect` → `openSettings`. If MainActivity does not
implement it, the app shows manual navigation instructions instead. Suggested
Kotlin (MainActivity):

```kotlin
MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "athlete_os/health_connect")
  .setMethodCallHandler { call, result ->
    if (call.method == "openSettings") {
      val action = if (Build.VERSION.SDK_INT >= 34)
        "android.health.connect.action.MANAGE_HEALTH_PERMISSIONS"
      else "androidx.health.ACTION_HEALTH_CONNECT_SETTINGS"
      val intent = Intent(action)
      if (Build.VERSION.SDK_INT >= 34) intent.putExtra(Intent.EXTRA_PACKAGE_NAME, packageName)
      try { startActivity(intent); result.success(true) } catch (e: Exception) { result.success(false) }
    } else result.notImplemented()
  }
```

## Publishing note

A sideloaded debug APK does not need any Play Console declaration. If the
app is ever published on Google Play, the **Health apps declaration** (Play
Console › App content) must be completed and each Health Connect permission
justified, with a privacy policy describing health-data use.

## Setup (user)

1. Update Samsung Health (6.22.5+); enable Settings › Health Connect inside
   Samsung Health and let it write the data types you want.
2. In Athlete OS: Health Connect screen (Integrations › Health Connect) →
   turn on the groups you want → read the explanation → Continue → allow in
   the Health Connect dialog.
3. Keep the watch syncing with Samsung Health. Pull to refresh in Athlete OS.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "The app cannot currently access step data" | Health Connect missing/outdated, Activity not enabled, or Steps permission revoked. Open the Health Connect status screen. Manual entry is always available. |
| Steps lower than Samsung Health | Samsung Health not writing to Health Connect, or another app ranks higher in Health Connect › Data and access › Steps › app priority. |
| Data older than ~30 days missing | Grant optional history access. |
| Heart rate is old | Watch HR syncs in batches; open Samsung Health, then pull to refresh. |
| Status shows an error | The last error is shown (secrets redacted). Partial failures are listed per data type; other types still import. |
