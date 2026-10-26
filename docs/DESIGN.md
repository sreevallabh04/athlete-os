# Athlete OS: Design System ("Stark HUD")

This document is for the engineers who rebuild every screen on top of the HUD system.
Read §1–§3 before you start, keep §6 open while you work, and run the screenshot tool (§9) before you open a PR.

```dart
import '../../../core/widgets/widgets.dart'; // components + motion + haptics + HudTheme
import '../../../core/theme/tokens.dart';    // AppColors, AppSpacing, AppRadii, …
```

---

## 1. Principles

1. **Stark-tech HUD, Apple-level restraint.** Think of a heads-up display seen through good glass. Luminous lines, thin brackets and glows are used to *frame information*, not to decorate it. If an element doesn't help someone read a number faster, delete it.
2. **One accent, one earned colour, one AI colour.** **Stark red** marks focus, selection, progress and primary actions; it *accents* and must never flood a screen. **Gold** is earned (PRs, streaks, goals hit, "done"). **Arc cyan belongs to JARVIS only** (see §2). Errors and "over target" use a hotter **coral** plus an icon and a label. Metric hues identify *data families* inside one warm family; they are not decoration.
3. **Warm charcoal is the canvas.** Pages are transparent over the app-wide `HudBackground` (a faint ember haze, a red/gold hex grid and twinkles). Don't paint opaque page backgrounds.
4. **Physical motion.** Anything you touch moves on a spring and answers with a haptic. Anything that arrives decelerates in. Everything respects reduced motion.
5. **Honesty is part of the look.** Show `SourceBadge`s, stale states and "not connected" without apology. The boot sequence never fakes "online", and screens shouldn't either.
6. **Numbers are the hero.** Use tabular figures, tickers for values that change, and big HUD numerals in rings and gauges.

## 2. Palette (`AppColors`): "Stark" red & gold

| Token | Hex | Use |
|---|---|---|
| `red` (= `brand`) | `#DD3439` | Primary accent: selection, progress, primary CTA (white label 4.5:1), focus, title rule |
| `redDeep` | `#B8262B` | Pressed states, deep fills, gradient stop |
| `redInk` / `redInkLight` | `#F04A4F` / `#B4232A` | Red **text** on charcoal / on porcelain (AA) |
| `gold` (= `brandAlt`, `success`, `habit`) | `#F2B544` | Achievements, PRs, streaks, "done" checks, connected |
| `goldLight` (= `mood`) | `#FFD27A` | Gold text/highlights on dark, celebration sparks |
| `goldInk` | `#8A5A00` | Gold text on porcelain (AA) |
| **`jarvis`** (`cyan` is a legacy alias) | `#3FD0FF` | **AI only**: orb, AI status, coach chat/composer, briefing strip, AI badges and estimate glyphs, AI food-log analysing state |
| `jarvisDeep` / `jarvisInk` | `#0E9FCC` / `#006F92` | AI fills on light / AI text on porcelain |
| `titanium` (= `info`) | `#B7B0A6` | Neutral information: tags, "auto", calendar, empty states |
| `warning` | `#FF9A3D` | Stale, estimate, needs attention (always with a label) |
| `danger` (= `over`) | `#FF6A4D` | Errors, destructive, **over target**: hotter and brighter than `red`, always paired with an icon and a label (`KCAL OVER` + warning glyph, `SYSTEM FAULT`) |
| `darkBg` / `darkBgAlt` | `#0A0A0C` / `#131215` | Charcoal canvas (bottom / top): warm-neutral, never navy |
| `darkSurface` / `darkSurfaceHigh` | `#151417` / `#1D1B1F` | Opaque surfaces (dialogs, sheets, dock) |
| `darkOutline` | `#2E2A2B` | Dividers on opaque surfaces |
| `darkText` / `darkTextMuted` / `darkTextFaint` | `#F4F1EC` / `#A8A299` / `#6A655F` | Body / secondary / decorative-only text |
| `lightBg` / `lightSurface` / `lightSurfaceHigh` | `#F6F3EE` / `#FFFFFF` / `#ECE6DE` | "Stark lab" porcelain |
| `lightText` / `lightTextMuted` | `#1A1719` / `#5E5850` | Charcoal text |

**The cyan rule.** Cyan means "JARVIS is involved" and nothing else. Use `AppColors.jarvis`, or the theme-aware `context.hud.jarvis` / `hud.jarvisInk`, on AI surfaces, and never for ordinary progress, selection or data. Everything that used to be cyan is now red (accent), titanium (neutral info) or a metric colour.

**Metric families** collapse into one red → amber → gold family plus titanium/steel, with luminance spaced so adjacent series stay apart:

| calories `#DD3439` (red) | protein `#FFD06E` (pale gold) | carbs `#E8822A` (amber) | fat `#C9466A` (rose) | fiber `#DCC48A` (wheat) |
|---|---|---|---|---|
| **water** `#5F7A90` (steel) | **steps** `#DCCDB8` (platinum) | **heart** `#E85A78` (rose-red) | **sleep** `#B9AE9F` (champagne silver) | **strength** `#DD3439` (red) |
| **running** `#F2782F` (ember) | **mood** `#FFD27A` | **habit** `#F2B544` | **competition** `#FF8A3D` | |

Today's concentric rings (steps → calories → protein → water) alternate light and dark: steps/calories 2.9:1, calories/protein 3.1:1, protein/water 3.1:1. In the macro orbit, protein/fat is 3.2:1, while protein/carbs and carbs/fat differ by hue (ΔE2000 ≥ 22) as well as lightness (1.9:1 and 1.7:1), and every sector carries its P/C/F letter. Every metric stroke is ≥ 3:1 against the canvas and cards (WCAG 1.4.11). Mood runs ash `#7D7770` → pewter → champagne → amber → gold, so luminance rises with mood and low moods are never red.

Contrast is enforced by `test/core/theme_test.dart` (body ≥ 7:1; muted, red ink, gold, jarvis and danger ≥ 4.5:1 on every dark surface; metric strokes ≥ 3:1; the adjacent-series pairs above). On the light theme, never set body text in a metric colour: use it for strokes, fills and icons, and `hud.accentInk` (`redInkLight`) for accent text.

Gradients (`AppGradients`): `brand` (red → deep red), `gold`, `competition` (red → gold), `jarvis` (AI only), `canvas`, `subtle(c)` (accent wash) and `hairline(c)` (luminous border). Glows (`AppGlows`): `soft(c)`, `strong(c)` (outer-only box shadows, so they never show through glass) and `text(c)` (for `Icon.shadows` / `TextStyle.shadows`).

Theme-dependent values live in **`HudTheme`** (`context.hud`): `accent` (red), `accentInk`, `jarvis`/`jarvisInk` (AI cyan), `glassFill(Strong)`, `hairline` (warm champagne), `text(Muted)`, `gridColor`, `glowStrength` (0.75 dark / 0.4 light) and `nebulaIntensity`. Prefer these over raw constants whenever the value should change with the theme. `hud.label/mono/number(color: …)` pass the colour through `hud.ink(c)`, which maps red/gold/jarvis to their hand-tuned inks and darkens other luminous hues on the light theme so coloured HUD text stays AA (dark theme and neutrals are untouched); use `hud.ink` yourself for any other coloured text.

## 3. Typography (`AppTypography`, `AppFonts`)

Bundled OFL fonts (`assets/fonts/`, licences in `OFL.txt`, registered with `LicenseRegistry`). The HUD faces (Rajdhani, JetBrains Mono) and every `AnimatedTicker` use **tabular figures**; the Inter text styles keep proportional figures because Inter's `tnum` also widens the hyphen (prose like "heart-rate" looked letter-spaced). Add `AppTypography.tabular` to an Inter style when a column of numbers must align.

| Role | Family | Style |
|---|---|---|
| UI (body, labels, titles) | **Inter** (opsz 14) 400/500/600/700 | `textTheme.*` |
| Headlines / large numbers | **Inter Display** (opsz 32) 600/700/800 | `display*`, `headline*` |
| HUD labels | **Rajdhani** 500/600/700 | `context.hud.label()` (pass UPPERCASE, letter-spaced 16 %) |
| Hero numerals | Rajdhani Bold | `context.hud.number(size: 40)` |
| Telemetry / timestamps / boot log | **JetBrains Mono** 400/600 | `context.hud.mono()` |

Scale: display 56/44/36 · headline 32/28/24 · title 20/16/14 · body 16/14/12.5 · label 14/12/11. Headlines use negative tracking (−0.4 to −1.8). Use Rajdhani for *short* labels only (≤ 3 words), never for sentences. Mono is for machine-ish text: times, IDs, status words.

## 4. Spacing, radii, layout

`AppSpacing`: 2 · 4 · 8 · **12** (default gap) · 16 (card padding) · 24 · 32 · 48; `gutter` = 20; `touchTarget` = 48.
`AppRadii`: xs 6 (chips/badges) · sm 10 · md 14 (buttons, inputs) · **lg 20 (cards)** · xl 28 (sheets) · dock 26.

* Page content sits inside `AppPage` with the 20 dp gutter. Headers come in two states only: the large AppPage title (every list/overview screen) and its collapsed bar (centred `titleMedium`). Pickers and editors that use a plain `AppBar` get that same compact bar from the theme; only Today, the AI coach, onboarding, the journal editor and the camera scanner have bespoke headers.
* Times are 24-hour (`Fmt.time` → `21:40`) and dates day-first (`Fmt.dayMonth` → `25 Oct`, `Fmt.weekdayDayMonth` → `Sun 25 Oct`). Durations read `6 h 52 min`.
* Every tappable is at least 48 dp (compact `HudButton`s keep a 40 px look inside a 48 dp target). A `Semantics(excludeSemantics: true)` wrapper drops its child's tap action: pass `onTap:` to it too (`test/app/accessibility_test.dart` fails otherwise). Cards stack with 12 dp gaps, and sections start with `SectionHeader` (24 dp above).
* Tap targets are at least 48 dp. Components are verified at 1.3× text scale on a 360 dp phone (`widgets_test.dart`).
* Bottom insets: the shell uses `Scaffold.extendBody`, so **`MediaQuery.padding.bottom` already includes the floating dock**. `AppPage`, `ListView` and FABs respect it automatically. If you hand-roll a bottom bar or composer in a tab, pad it with `MediaQuery.paddingOf(context).bottom`.

## 5. Motion (`core/motion`) and haptics (`core/haptics`)

**Tokens (`AppMotion`)**: `micro` 90 · `short` 160 · `medium` 280 · `long`/`page` 420 (reverse 300) · `entrance` 520 · `data` 900 ms.
Curves: `standard`, `emphasized`, `emphasizedDecelerate` (arrivals), `emphasizedAccelerate` (exits).
Springs: `snappy` (press, toggles), `bouncy` (release, indicators), `gentle` (sheets, large surfaces). `SpringCurve(spring)` turns a spring into a `Curve` for duration-based APIs.

**Patterns**

| Pattern | API | Notes |
|---|---|---|
| Press physics | `PressableScale(onTap:, child:)` | Sinks to 96.5 %, rebounds with overshoot, haptic, keyboard activation. `AppCard`, `HudButton`, `HudChip` and the dock already use it. |
| Entrance | `Entrance(delay:, child:)` | Fade, 14 dp rise, optional scale/blur. Same widget tree before and after the animation, so child state survives. |
| Stagger | `StaggeredList(children:)` / `staggered(list)` | 45 ms steps, capped at 8 items. |
| Auto-cascade | automatic | `AppCard`s mounted within 2.5 s of their `AppPage` appearing cascade in. Later mounts (scrolling, refresh) are instant. |
| Number ticker | `AnimatedTicker('8,432')` / `.value(72.5, fractionDigits: 1)` | Odometer roll. The final string is always a real `Text`, so `find.text` works. `StatTile` uses it. |
| Page transition | automatic (`PageTransitionsTheme`) | "Zoom-through" on all platforms. For GoRouter `pageBuilder:` use `hudPage(state, child)`. |
| Tab switch | automatic | Fade-through and 98 %→100 % in the shell. |
| Ring sweep | `ProgressRing` | 900 ms emphasized sweep. When progress crosses 1.0 on screen you get a bloom pulse, `CelebrationBurst` and the goal-reached haptic. |

**Reduced motion**: every component checks `AppMotion.reduced(context)` and jumps to its end state. Background, orb and spinners freeze, the boot sequence is skipped, and transitions become fades. Do the same in custom animations.

**Haptics (`Haptics`)**: call the *meaning*, never `HapticFeedback` directly.

| Call | When |
|---|---|
| `selection()` | tab/segment change, picker detents, chip toggles |
| `light()` | ordinary taps (default for `PressableScale`) |
| `medium()` | confirm/commit (primary `HudButton`, long-press) |
| `heavy()` | destructive confirmation |
| `success()` | an action completed (medium → light) |
| `warning()` | validation problem (heavy ×2) |
| `goalReached()` | a goal completes (rising cascade) |

There is one global switch: AppSettings key **`ui.haptics`** (JSON bool, default `true`). The app root keeps `Haptics.enabled` in sync with it, so a settings screen just writes the key: `settingsRepository.set(Haptics.settingKey, false)`.

## 6. Component catalogue

All components are exported from `core/widgets/widgets.dart`, and every one is shown live at **`/dev/gallery`** (`context.push(AppPaths.devGallery)`).

### Surfaces
* **`AppCard`** (existing API, plus new optional params): glass slab with a luminous hairline.
  `AppCard(accent: AppColors.protein, onTap: …, brackets: true, glow: true, child: …)`. `accent` adds a tinted wash and light spill. `brackets` adds HUD corner brackets (hero/focus cards only, at most one or two per screen). `glow` adds an accent bloom. `gradient` replaces the fill. `onLongPress` and `animateEntrance` are also available. Contains a transparent `Material`, so `ListTile`/`InkWell` ink works inside.
* **`GlassPanel`**: the same glass without card semantics. Set `blur:` only for chrome floating over moving content.
* **`HudFrame`**: corner brackets around any child, with optional `ticks` and a mono `tag` (`'SYS·01'`).
* **`AppPage`** (existing API, plus `eyebrow`): large Inter Display title that blurs in, a HUD rule underneath, and a collapse into a frosted bar. Transparent over the background. Pull-to-refresh, back/close button and actions as before. A pushed screen's primary action goes in `bottomAction:` (a docked frosted bar the list ends above, so it never covers content); keep `floatingActionButton` for tab roots that float over the dock (Nutrition's quick-add).
* **`SectionHeader`** (existing API, plus `accent`): glowing marker, title, and a tick line that fades out.

### Data
* **`ProgressRing`** (existing API, plus `celebrate`, `ticks`): arc-reactor ring with tick bezel, segmented track, glowing sweep and a white-hot head.
* **`ArcGauge`**: half-circle gauge: `ArcGauge(value: .72, valueText: '72', label: 'READINESS', color: AppColors.habit)`.
* **`MetricBar`** (existing API, plus `segments`): luminous segmented bar. Use `segments: 0` for a continuous bar.
* **`StatTile`** (existing API): label, ticker value and sub-line.
* **`HudSparkline`**: glowing mini line that draws in. (Named `HudSparkline` because `train/…/charts.dart` already has a `Sparkline`.)
* **`HudChartStyle`**: fl_chart presets: `grid()`, `noBorder`, `titles()`, `axisLabel()`, `line(spots, color)`, `rod(y, color)`, `lineTouch()`, `barTouch()`. Every chart in the app should use these.
* **`SourceBadge`** (existing API): HUD chip with a glowing status dot. Turns amber for estimate, stale or sample data.

### Controls
* **`HudButton`** / `.secondary` / `.ghost` / `variant: HudButtonVariant.danger`, with `icon`, `loading`, `expand` and `compact`. Use one primary per screen. Material `FilledButton`/`OutlinedButton`/`TextButton` are themed to match and are fine for secondary UI.
* **`HudChip`**: letter-spaced chip with `selected`, `dot`, `icon` and `color`.
* **`HudToggle`**: spring switch with a glowing thumb (Material `Switch` is themed too).
* **`SegmentedHud<T>`**: segments with a sliding glow indicator.
* **`GlowIcon`**: icon with bloom, or `framed: true` for a ring badge.
* **`showHudBottomSheet(context, title:, builder:)`**: frosted sheet on a gentle spring. **`HudSheet`** is the chrome on its own.

### States & feedback
* **`EmptyState`** (existing API, plus `eyebrow`, `color`): icon in a slowly scanning reticle (titanium by default, so it never reads as an error). Copy voice: calm, specific, helpful ("No meals logged yet. Snap a photo or search a food to start today's tally.").
* **`ErrorState`** (existing API, plus `title`, `eyebrow`): coral (`danger`) reticle, `SYSTEM FAULT` eyebrow, human headline.
* **`LoadingState`** (existing API, plus `label`, `compact`): `HudSpinner`. For content-shaped placeholders use **`ScanlineLoader(lines: 3)`** or `ScanlineLoader(height: 140, lines: 0)`.
* **`NoticeBanner`** (existing API): tinted glass with a glowing edge bar.
* **`CelebrationBurst(controller:, child:)`** + `CelebrationController.fire()`: shockwave and sparks painted over any widget.

### Assistant
* **`JarvisOrb(state: OrbState.idle|listening|thinking|speaking, level: micLevelStream, size: 180)`**: animated reactor orb, always JARVIS cyan. States cross-fade. `level` is a `Stream<double>` 0..1 used while listening. Use `fps: 30` for small decorative orbs.

### Chrome
* **`HudDock`** / **`HudDockItem`**: floating glass dock (used by `AppShell`). It has a spring indicator, icon morph, an orb slot and a selection haptic. A bottom scrim dissolves content as it slides under the dock.
* **`HudBackground`**: warm charcoal shader (faint red ember haze with a gold undertone, red/gold hex grid) with a painter fallback, capped at 30 fps and paused when the app is inactive or reduced motion is on. The app root already paints one, so don't add another.
* **`AthleteEmblem`** / `EmblemPainter`: the brand mark.

## 7. Do / Don't

| Do | Don't |
|---|---|
| Use `AppCard`/`GlassPanel` for surfaces and leave the canvas visible | Paint opaque page or Scaffold backgrounds |
| Keep red for the one thing that matters on the screen | Flood a screen with red, or use red for errors (that's `danger` + icon) |
| Keep cyan for JARVIS/AI surfaces | Use cyan for progress, selection or data |
| Use metric colours only for their data family | Use `AppColors.protein` because "green looks nice" |
| Use `AnimatedTicker`/`StatTile` for changing numbers | Animate numbers with ad-hoc `setState` loops |
| Wrap custom tappables in `PressableScale` | Use bare `GestureDetector`s (no feedback) or ink ripples on glass |
| Call semantic `Haptics.*` | Call `HapticFeedback` directly or fire haptics on scroll |
| Use `BackdropFilter` only on chrome over moving content | Blur every card (re-renders every background frame) |
| Use brackets/glow on one or two hero cards | Frame everything (it becomes noise) |
| Keep `Semantics` labels and test at 1.3× text | Bake text into painters without a semantics label |
| Check `AppMotion.reduced` in custom animations | Assume motion is always allowed |
| Write honest copy: "Not connected", "Estimate" | Show fake "online"/sample data without a badge |

## 8. Shell, boot, icon

* **Shell** (`lib/app/shell.dart`): phones get the floating `HudDock` (Today · Train · Nutrition · **AI Coach orb** · Life). At ≥ 840 dp you get a frosted `NavigationRail`. `StatefulNavigationShell` behaviour is unchanged.
* **Boot sequence** (`lib/app/boot/`): plays once per process on a cold start, takes about 1.6 s and is skippable by tap. The emblem ignites from the exact native-splash position (108 dp), then HUD lines draw in, a time-aware greeting types out (profile `displayName`, if set), and four honest system checks run from `integrationStatusesProvider` (LOCAL DATA, HEALTH CONNECT, AI CORE, CALENDAR). It then zoom-reveals the app. It is disabled with reduced motion and under `flutter test`; override `bootSequenceEnabledProvider` to test it.
* **App icon**: an original mark. A segmented hexagon "reactor housing" (gaps and nodes at the vertices, like HUD brackets) encloses a faceted Λ monogram (an A for Athlete, and an upward chevron for progress). Its crossbar is a white-hot energy cell. A Stark-red segmented housing with gold vertex nodes and a faceted gold monogram (light → bronze) sit on a warm charcoal field with a faint red hex lattice and a gold top light. It reads clearly at 48 px (`assets/icon/preview_48.png`) and contains no third-party marks. It is rendered by the same `EmblemPainter` the app uses:
  `flutter test tool/render_icon_test.dart && dart run flutter_launcher_icons && dart run flutter_native_splash:create`.
  This produces the master (`assets/icon/icon.png`), adaptive foreground/background, the Android 13 themed monochrome icon, the splash and the Android 12 splash. The notification small icon is `res/drawable/ic_stat_jarvis.xml`.

## 9. Visual QA: `tool/screenshots_test.dart`

This renders real routes (real router, in-memory DB, bundled fonts and icons) at **1080×2400 px, DPR 2.75**, the reference OPPO phone, into `build/shots/*.png`.

```sh
flutter test tool/screenshots_test.dart                       # the standard set
flutter test tool/screenshots_test.dart --plain-name gallery  # one shot
flutter test tool/screenshots_test.dart --dart-define=SHOT_ROUTE=/settings --dart-define=SHOT_NAME=settings --dart-define=SHOT_SCROLLS=2
```

In your own test, call `shotRoute(tester, '/route', 'name', scrolls: 2, light: true, overrides: [...], prepare: (t) async {...})`. GPU shaders are off under `flutter test`, so you'll see the painter fallbacks (designed to match). The test rasteriser also draws blurred box shadows harder than devices do, so judge glows on a real phone. Always look at your screens in both themes and with scrolled states before opening a PR.

## 10. API changes for screen engineers

* **No breaking changes** to `AppColors.*`, `AppSpacing.*`, `AppRadii.*`, `AppDurations.*`, `AppGradients.*`, `AppTheme.dark()/light()`, `AppPage`, `AppCard`, `SectionHeader`, `ProgressRing`, `MetricBar`, `StatTile`, `SourceBadge`, `EmptyState`, `ErrorState`, `LoadingState`, `NoticeBanner` or `spaced()`. Only optional parameters were added.
* `AppColors.brand` is now **Stark red** and `brandAlt` is **gold**, so existing call sites re-skin automatically. `AppColors.red` is the brand red: use `AppColors.danger` for errors and destructive actions, and `AppColors.jarvis` for AI (`cyan` remains as an alias).
* `scaffoldBackgroundColor` is **transparent**. Raw `Scaffold`s show the HUD background, which is intended.
* The bottom `NavigationBar` is gone. Tests should look for `HudDock` (see `test/app_smoke_test.dart`).
* `FilledButton` no longer has elevation. Use `HudButton` when you want bloom.
* New route: `AppPaths.devGallery` (`/dev/gallery`).
