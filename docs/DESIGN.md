# Athlete OS: Design System ("JARVIS HUD")

This document is for the engineers who rebuild every screen on top of the HUD system.
Read §1–§3 before you start, keep §6 open while you work, and run the screenshot tool (§9) before you open a PR.

```dart
import '../../../core/widgets/widgets.dart'; // components + motion + haptics + HudTheme
import '../../../core/theme/tokens.dart';    // AppColors, AppSpacing, AppRadii, …
```

---

## 1. Principles

1. **Stark-tech HUD, Apple-level restraint.** Think of a heads-up display seen through good glass. Luminous lines, thin brackets and glows are used to *frame information*, not to decorate it. If an element doesn't help someone read a number faster, delete it.
2. **One accent.** Arc-reactor **cyan** marks focus, selection, progress and primary actions. **Gold** is earned (PRs, streaks, goals hit). **Red** is for alerts and destructive actions only. Metric hues identify *data families*; they are not decoration.
3. **Dark space is the canvas.** Pages are transparent over the app-wide `HudBackground` (a slow nebula, a faint hex grid and twinkles). Don't paint opaque page backgrounds.
4. **Physical motion.** Anything you touch moves on a spring and answers with a haptic. Anything that arrives decelerates in. Everything respects reduced motion.
5. **Honesty is part of the look.** Show `SourceBadge`s, stale states and "not connected" without apology. The boot sequence never fakes "online", and screens shouldn't either.
6. **Numbers are the hero.** Use tabular figures, tickers for values that change, and big HUD numerals in rings and gauges.

## 2. Palette (`AppColors`)

| Token | Hex | Use |
|---|---|---|
| `cyan` (= `brand`, `info`) | `#36E2FF` | Primary accent: selection, progress, primary CTA, focus |
| `cyanDeep` | `#00A9D4` | Fills behind light text; light-theme accent strokes |
| `cyanInk` | `#007A99` | Cyan **text** on light backgrounds (AA) |
| `gold` (= `brandAlt`) | `#FFC24B` | Achievements, PRs, streaks, "goal reached" |
| `red` (= `danger`) | `#FF4D3D` | Alerts, destructive actions, errors |
| `success` | `#3EE68B` | Connected / completed states |
| `warning` | `#FFB547` | Stale, estimate, needs attention |
| `darkBg` / `darkBgAlt` | `#04060B` / `#070B14` | Canvas gradient (bottom / top) |
| `darkSurface` / `darkSurfaceHigh` | `#0A101B` / `#111A28` | Opaque surfaces (dialogs, sheets) |
| `darkOutline` | `#1D2B3D` | Dividers on opaque surfaces |
| `darkText` / `darkTextMuted` | `#E8F1FA` / `#8EA3B8` | Body / secondary text (≥ 7:1 and ≥ 4.5:1) |
| `lightBg` / `lightSurface` | `#F3F5F8` / `#FFFFFF` | "Stark lab" porcelain |
| `lightText` / `lightTextMuted` | `#11161D` / `#55606E` | Graphite text |

**Metric families** (luminous, slightly desaturated, similar perceived brightness):

| calories `#FF8F4D` | protein `#3EE6A0` | carbs `#6E9BFF` | fat `#FFCF5C` | fiber `#B4EC5A` |
|---|---|---|---|---|
| **water** `#45C4FF` | **steps** `#B07CFF` | **heart** `#FF5A76` | **sleep** `#8F94FF` | **strength** `#FF72B6` |
| **running** `#FF6A2B` | **mood** `#FFD84D` | **habit** `#3DE0C8` | **competition** `#E47BFF` | |

Contrast is enforced by `test/core/theme_test.dart` (body ≥ 7:1, muted, cyan and gold ≥ 4.5:1 on every dark surface). On the light theme, never set body text in a metric colour: use it for strokes, fills and icons, and `cyanInk` for accent text.

Gradients (`AppGradients`): `brand` (cyan → blue), `gold`, `competition`, `canvas`, `subtle(c)` (accent wash) and `hairline(c)` (luminous border). Glows (`AppGlows`): `soft(c)`, `strong(c)` (outer-only box shadows, so they never show through glass) and `text(c)` (for `Icon.shadows` / `TextStyle.shadows`).

Theme-dependent values live in **`HudTheme`** (`context.hud`): `accent`, `accentInk`, `glassFill(Strong)`, `hairline`, `text(Muted)`, `gridColor`, `glowStrength` (1.0 dark / 0.45 light) and `nebulaIntensity`. Prefer these over raw constants whenever the value should change with the theme. `hud.label/mono/number(color: …)` pass the colour through `hud.ink(c)`, which darkens luminous metric hues on the light theme so coloured HUD text stays AA (dark theme and neutrals are untouched); use `hud.ink` yourself for any other coloured text.

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
* **`EmptyState`** (existing API, plus `eyebrow`, `color`): icon in a slowly scanning reticle. Copy voice: calm, specific, helpful ("No meals logged yet. Snap a photo or search a food to start today's tally.").
* **`ErrorState`** (existing API, plus `title`, `eyebrow`): red reticle, `SYSTEM FAULT` eyebrow, human headline.
* **`LoadingState`** (existing API, plus `label`, `compact`): `HudSpinner`. For content-shaped placeholders use **`ScanlineLoader(lines: 3)`** or `ScanlineLoader(height: 140, lines: 0)`.
* **`NoticeBanner`** (existing API): tinted glass with a glowing edge bar.
* **`CelebrationBurst(controller:, child:)`** + `CelebrationController.fire()`: shockwave and sparks painted over any widget.

### Assistant
* **`JarvisOrb(state: OrbState.idle|listening|thinking|speaking, level: micLevelStream, size: 180)`**: animated reactor orb. States cross-fade. `level` is a `Stream<double>` 0..1 used while listening. Use `fps: 30` for small decorative orbs.

### Chrome
* **`HudDock`** / **`HudDockItem`**: floating glass dock (used by `AppShell`). It has a spring indicator, icon morph, an orb slot and a selection haptic. A bottom scrim dissolves content as it slides under the dock.
* **`HudBackground`**: shader nebula with a painter fallback, capped at 30 fps and paused when the app is inactive or reduced motion is on. The app root already paints one, so don't add another.
* **`AthleteEmblem`** / `EmblemPainter`: the brand mark.

## 7. Do / Don't

| Do | Don't |
|---|---|
| Use `AppCard`/`GlassPanel` for surfaces and leave the canvas visible | Paint opaque page or Scaffold backgrounds |
| Keep cyan for the one thing that matters on the screen | Use cyan, gold and red together on one card |
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
* **App icon**: an original mark. A segmented hexagon "reactor housing" (gaps and nodes at the vertices, like HUD brackets) encloses a faceted Λ monogram (an A for Athlete, and an upward chevron for progress). Its crossbar is a white-hot energy cell. Cyan → blue on a deep-navy field with a faint hex lattice. It reads clearly at 48 px (`assets/icon/preview_48.png`) and contains no third-party marks. It is rendered by the same `EmblemPainter` the app uses:
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
* `AppColors.brand` is now **cyan** and `brandAlt` is **gold**, so existing call sites re-skin automatically.
* `scaffoldBackgroundColor` is **transparent**. Raw `Scaffold`s show the HUD background, which is intended.
* The bottom `NavigationBar` is gone. Tests should look for `HudDock` (see `test/app_smoke_test.dart`).
* `FilledButton` no longer has elevation. Use `HudButton` when you want bloom.
* New route: `AppPaths.devGallery` (`/dev/gallery`).
