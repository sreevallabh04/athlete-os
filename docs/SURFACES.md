# Home-screen surfaces (Android)

Glanceable info and one-tap actions without opening the app: the **JARVIS
Today** widget, **launcher shortcuts**, **deep links** and a **Quick Settings
tile**. Target device: OPPO CPH2251 (Android 13 / ColorOS 13, 1080×2400).

Code:

| Side | Path |
| --- | --- |
| Dart | `lib/features/surfaces/**` (bootstrap hook registered in `lib/app/bootstrap.dart`) |
| Kotlin | `android/app/src/main/kotlin/com/athleteos/athlete_os/surfaces/**` (registered in `MainActivity.kt`) |
| Resources | `res/layout/surf_widget_*.xml`, `res/xml/surf_jarvis_today_info.xml`, `res/xml/shortcuts.xml`, `res/drawable/surf_*`, `res/drawable/ic_surf_*`, `res/values/surfaces.xml` |
| Manifest | the two blocks marked `===== Surfaces … begin/end =====` |
| Tests | `test/features/surfaces/**` |

No packages were added. `home_widget` (0.10.0 on pub.dev) was evaluated: it
would only replace ~40 lines (save JSON + broadcast an update), while its
interactive callbacks start a headless Flutter engine per tap (slower, more
battery). We need native code anyway for the durable water queue, so the
widget is plain Kotlin + RemoteViews over two small platform channels.

## 1. JARVIS Today widget

Default 4×2, resizable down to 2×2.

| Section | Shows | Tap opens |
| --- | --- | --- |
| Header | JARVIS mark · today's planned session (`Upper A · Push`, `✓ …` in gold once a workout is logged today, `TODAY` when there is no program) · time of the last data change | Today (`/today`) · session → Program (`/train/program`) |
| Steps | value / step goal | Steps (`/steps`) |
| Protein | grams / protein target | Nutrition (`/nutrition`) |
| Kcal | kcal / calorie target | Nutrition (`/nutrition`) |
| Water | litres / water goal | Hydration (`/hydration`) |
| Next | next routine block (`NEXT 18:30 Evening walk`) | Routine (`/routine`) |
| **+250 ml** | logs 250 ml water directly (no app launch) | — |

The compact layout (2×2 and 3×2) shows the four metrics, the update time and
the +250 ml button. On Android 12+ the launcher switches layouts itself as you
resize (`RemoteViews` size map, wide from 250 dp); on older versions the
widget re-renders on `onAppWidgetOptionsChanged`.

**Honesty rules** (`buildWidgetSnapshot` + `WidgetRenderer.kt`):

* A value appears only if it was logged/synced **today**. No food logs → protein
  and kcal show `—`; no water logs → `—` (not `0`); no step data yet → `—`.
  The target is always shown next to it.
* A snapshot from another day is never shown as today's: the native renderer
  compares the snapshot date with the phone's date and blanks every value
  (and says "Open Athlete OS to refresh today") until the app pushes a new one.
* The widget-picker preview uses the layout's static text: dashes only.
* Goal reached → value and bar turn gold (gold is earned, per DESIGN.md).

**Styling.** Warm charcoal glass slab (`#141316 → #0A0A0C`, 95 % opaque) with a
champagne hairline and Stark-red corner brackets, red gradient progress bars,
metric-family dots (steps platinum, protein gold, kcal red, water steel), mono
timestamps and a Stark-red primary button. Only the "JARVIS Today" label and
icon are arc cyan (cyan is reserved for the AI). Everything is vector/shape drawables, so it
is crisp at any density and costs no bitmap memory. Rendering a Flutter widget
to a bitmap (`home_widget.renderFlutterWidget`) was rejected: it needs the
engine running for every refresh, bitmaps blur when the launcher rescales them
and they count against the RemoteViews memory limit.

### Data flow

```
Drift tables ─▶ todaySnapshotProvider ┐
program/readiness ─▶ todaysPlannedSessionProvider ├─▶ widgetSnapshotProvider ─▶ WidgetSyncService
calibration ─▶ todaysRoutineProvider ┘          (≤ 1 push / 15 s, only on change)
                                                        │ MethodChannel athlete_os/surfaces · updateWidget(json)
                                                        ▼
                                SurfaceStore (private SharedPreferences) ─▶ JarvisTodayWidget.updateAll
```

The snapshot is recomputed whenever any table behind the Today dashboard
changes — food log, water, Health Connect step sync, workouts, **profile
targets** — plus the program and routine. `PushThrottle` sends the first change
immediately, coalesces later ones to at most one per 15 s, skips identical
content, and flushes the pending one when the app goes to the background. At
local midnight the providers are invalidated so the new day starts clean.

### +250 ml (widget button and tile)

```
tap ─▶ SurfaceActionReceiver (not exported) ─▶ SurfaceStore.enqueueWater   (durable, id "w-<uuid>")
                                            ├▶ widget re-render (tap visible immediately)
                                            └▶ if Flutter is running: event "water_queued"
Flutter (now, or on next start/resume) ─▶ WaterQueueDrainer:
     peek ─▶ WaterRepository.add(250, source 'widget'|'qs_tile', at: tap time,
                                 id: stableId('surface_water', nativeId))  (insert-or-ignore)
          ─▶ ack (remove) only what was stored
```

* **Exactly once:** the row id is derived from the native id, so a drain
  repeated after a lost ack (process killed between store and ack) or two
  overlapping drains still create one water log. Tested.
* The water log keeps the **tap time**, so a tap at 23:50 counts for that day
  even if the app only drains it the next morning.
* While a tap is still queued the widget adds it to the displayed water total
  (only taps newer than the snapshot, so nothing is double counted).
* Taps within 700 ms are treated as one (accidental double fire); deliberate
  repeated taps each log 250 ml. Undo from the Hydration list.
* Queue is capped at 200 entries (oldest dropped); malformed entries are
  dropped by the drainer.

### Update cadence & battery

| Trigger | When | Cost |
| --- | --- | --- |
| App push | on data change, ≤ 1 / 15 s, only while the app process runs | one SharedPreferences write + RemoteViews update |
| Water tap | immediately | same |
| `updatePeriodMillis` | every 30 min (platform minimum) | re-render from stored JSON, no engine |
| Boundary alarm | next routine block start / just after midnight | **non-wakeup**, inexact `AlarmManager.RTC`: delivered when the screen is next on, never wakes the phone |

No services, no WorkManager, no polling, no network. Background data only
changes when the app process is alive (Health Connect sync etc. happen inside
the app), so the widget can't be fresher than the app's last run — the header
time tells you when that was.

## 2. Launcher shortcuts

Long-press the Athlete OS icon (or drag a shortcut to the home screen):

| Shortcut | Link | Result |
| --- | --- | --- |
| Log water | `athleteos://open/hydration?quickAdd=1` | Hydration screen + quick-add sheet (150/250/500/750 ml; nothing is logged until you tap) |
| Log meal | `athleteos://open/nutrition/add` | Add food (meal pre-selected by time of day) |
| Ask JARVIS | `athleteos://open/coach?listen=1` | Coach tab; `listen=1` starts listening on arrival (same mic explainer + permission flow as a mic tap; a calm notice if the AI core is offline) |
| Today's session | `athleteos://open/session` | Program screen with today's session and **Start session** |

Static (`res/xml/shortcuts.xml`), with explicit `targetClass` so they always
reach `MainActivity`. Icons are adaptive (charcoal + faint red reactor ring +
red glyph; "Ask JARVIS" keeps its cyan glyph) with a monochrome layer for themed icons.

## 3. Deep links

`athleteos://open/<route>[?param=value]`, handled by `MainActivity`
(`SurfaceEvents.handleIntent`) and routed in Dart by `DeepLinkRouter`.

**Allowlist** (`lib/features/surfaces/domain/deep_links.dart`) — nothing else is
ever navigated to:

| Link path | Screen | Mode | Params |
| --- | --- | --- | --- |
| `today`, `train`, `nutrition`, `life` | tab | go | — |
| `coach` | Coach tab | go | `listen=1` |
| `nutrition/add` | Add food | push | `meal=breakfast\|lunch\|dinner\|snack` |
| `hydration` | Hydration | push | `quickAdd=1` (opens the sheet) |
| `steps`, `health`, `routine`, `assistant` | — | push | — |
| `session`, `train/program` | Program | push | — |

Unknown paths, extra segments, `..`, ports/user-info, duplicate or unknown
query parameters and out-of-range values are dropped; links over 512 chars are
rejected. Pushing a screen that is already on top doesn't stack a copy.

Safety notes:

* Flutter's built-in deep linking is **disabled** (`shouldHandleDeeplinking() =
  false` in `MainActivity`) — otherwise the raw URI path would be pushed into
  GoRouter and bypass the allowlist.
* The intent filter is scoped to host `open` and has **no `BROWSABLE`**
  category, so web pages can't trigger it. OAuth redirects
  (`athleteos://localhost/strava`, `athleteos://localhost/auth`) still go only
  to `flutter_web_auth_2`'s `CallbackActivity`.
* Known limit: `CallbackActivity`'s filter matches every `athleteos://` URI
  (scheme only). An *implicit* `athleteos://open/...` intent from another app
  or `adb` therefore shows a chooser between "Athlete OS" and the auth callback.
  All our own surfaces use explicit intents, so they are unaffected. Fix
  (owner of the OAuth setup): add `android:host="localhost"` to that filter.
* Test from a PC:
  `adb shell am start -n com.athleteos.athlete_os/.MainActivity -a android.intent.action.VIEW -d "athleteos://open/hydration?quickAdd=1"`

## 4. Quick Settings tile

"Water +250 ml": pull down Quick Settings › edit (pencil) › drag **Water +250
ml** into the active tiles. One tap queues 250 ml exactly like the widget
button (source `qs_tile`); the subtitle confirms `+250 ml saved · 14:32`. On the
lock screen it asks you to unlock first (no pocket logging). It is an action
tile, so it never shows as "on".

## Adding the widget on ColorOS (OPPO CPH2251)

1. Long-press an empty spot on the home screen › **Widgets** (on some ColorOS
   builds: pinch in › Widgets).
2. Search or scroll to **Athlete OS › JARVIS Today**, drag it onto the home
   screen. It lands as 4×2; long-press › resize handles to make it 2×2.
3. Open Athlete OS once so it pushes the first snapshot (until then the
   widget shows dashes and "Open Athlete OS once to connect").
4. Recommended for freshness (same steps as the assistant, see
   MESSAGING_ASSISTANT.md): Settings › Battery › App battery management ›
   Athlete OS › **Allow background activity** + **Allow auto launch**, and lock
   the app in Recents.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Widget shows dashes and "Open Athlete OS to refresh today" | The stored snapshot is from another day (app not opened since midnight). Open the app; it pushes within a second. |
| A value shows `—` though you logged it | Logged on another day/time zone, or the app hasn't run since. Opening the app refreshes it. Steps stay `—` until Health Connect has delivered today's steps. |
| "+250 ml" did nothing visible | Taps within 700 ms count once. Otherwise check the Hydration screen — the entry is created when the app next runs (the widget already includes it). |
| Water logged twice | Shouldn't happen: each tap has a unique id and the store is insert-or-ignore. Two entries means two taps; delete one in Hydration. |
| Widget not updating at all | ColorOS may freeze the app's broadcasts when battery restricted: apply step 4 above. Removing and re-adding the widget forces a full update. |
| Shortcut shows a chooser | Only for links sent implicitly by other apps (see Known limit). Our shortcuts use explicit intents. |
| "Next" is stale | Updated at each block start when the screen is on, otherwise at the next 30-minute refresh or when the app pushes. |
| Tile missing from the edit list | Reboot or reinstall; ColorOS caches the tile list. |

## Platform limits

* Widgets can't run code on their own schedule more often than every 30 min
  (`updatePeriodMillis`); everything faster is pushed by the app or triggered
  by a user tap.
* RemoteViews only support a fixed set of views (no custom fonts, shaders or
  blur) — the HUD look is approximated with shapes, gradients and system
  condensed/mono fonts.
* ColorOS may kill the app process and defer non-wakeup alarms; the widget
  then shows the last snapshot with its time until the app runs again.
* `targetCellWidth/Height` and size-mapped layouts need Android 12+; older
  launchers use `minWidth/minHeight` (250 × 110 dp).
