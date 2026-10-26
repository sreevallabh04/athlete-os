import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/paths.dart';
import '../../../core/config/env.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/integration_status_repository.dart';
import '../../train/application/train_providers.dart';
import '../../train/data/hevy_sync_service.dart';
import '../../train/data/strava_auth.dart';
import '../../train/data/strava_sync_service.dart';
import '../../train/presentation/widgets/hud_kit.dart';
import '../../train/presentation/widgets/strava_branding.dart';
import '../../train/presentation/widgets/sync_status.dart';
import '../data/api_errors.dart';
import '../data/google_calendar_service.dart';

/// Integrations hub: one tile per data link with a brand-neutral glyph, a
/// status glow, what it brings in and the last sync. Tap a tile for the
/// full capability list, setup steps and actions in a sheet. Status reads
/// "Connected" only after a real successful call.
class IntegrationsScreen extends ConsumerWidget {
  const IntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(integrationStatusesProvider).value ?? const [];
    IntegrationConnection? row(String p) =>
        rows.where((r) => r.provider == p).firstOrNull;
    final now = ref.watch(clockProvider).now();
    final statuses = [
      displayStatus(row(Providers.hevy)),
      displayStatus(row(Providers.strava), configured: Env.hasStrava),
      displayStatus(row(Providers.healthConnect)),
      displayStatus(row(Providers.googleCalendar), configured: Env.hasGoogle),
    ];
    int count(bool Function(IntegrationDisplayStatus) f) =>
        statuses.where(f).length;
    return AppPage(
      title: 'Integrations',
      eyebrow: 'OFFICIAL APIS ONLY · READ-FIRST',
      children: [
        _SummaryCard(
          online: count((s) => s == IntegrationDisplayStatus.connected),
          setup: count(
            (s) =>
                s == IntegrationDisplayStatus.needsSetup ||
                s == IntegrationDisplayStatus.disconnected ||
                s == IntegrationDisplayStatus.error,
          ),
          awaiting: count(
            (s) => s == IntegrationDisplayStatus.awaitingCredentials,
          ),
        ),
        const SectionHeader('Training'),
        StaggeredList(
          gap: AppSpacing.md,
          children: [
            _HevyTile(row: row(Providers.hevy), now: now),
            _StravaTile(row: row(Providers.strava), now: now),
            _HealthConnectTile(row: row(Providers.healthConnect), now: now),
          ],
        ),
        const SectionHeader('Planning'),
        _GoogleTile(row: row(Providers.googleCalendar), now: now),
        const SectionHeader('Food & AI'),
        StaggeredList(
          gap: AppSpacing.md,
          children: [
            _StaticTile(
              glyph: 'AI',
              title: 'AI providers',
              color: AppColors.cyan,
              status: displayStatus(row(Providers.aiBackend)),
              row: row(Providers.aiBackend),
              now: now,
              capabilities: const [
                'AI coach chat, meal estimates, weekly insights',
                'Never receives Strava data (Strava API policy)',
              ],
              actionLabel: 'AI provider settings',
              onAction: () => context.push(AppPaths.aiSettings),
            ),
            _StaticTile(
              glyph: 'OF',
              title: 'Open Food Facts',
              color: AppColors.protein,
              status: row(Providers.openFoodFacts) == null
                  ? null
                  : displayStatus(row(Providers.openFoodFacts)),
              infoChip: 'No account needed',
              row: row(Providers.openFoodFacts),
              now: now,
              capabilities: const ['Barcode lookup', 'Food search'],
              note:
                  'Data © Open Food Facts contributors, available under the '
                  'Open Database License (ODbL).',
            ),
            _StaticTile(
              glyph: 'US',
              title: 'USDA FoodData Central',
              color: AppColors.carbs,
              status: Env.usdaApiKey.isEmpty
                  ? IntegrationDisplayStatus.awaitingCredentials
                  : displayStatus(row(Providers.usda)),
              row: row(Providers.usda),
              now: now,
              capabilities: const [
                'Generic food nutrient data (public domain)',
              ],
              note:
                  'Optional. Provide a free api.data.gov key via build '
                  'config.',
              setupSteps: const [
                HudStep(
                  'Get a key',
                  'https://fdc.nal.usda.gov/api-key-signup.html',
                ),
                HudStep(
                  'Add it to the build',
                  'Put "USDA_API_KEY" in config/dev.json and rebuild.',
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.online,
    required this.setup,
    required this.awaiting,
  });
  final int online;
  final int setup;
  final int awaiting;

  @override
  Widget build(BuildContext context) {
    final total = online + setup + awaiting;
    return AppCard(
      brackets: true,
      semanticLabel:
          '$online of $total data links connected, $setup need setup, '
          '$awaiting awaiting credentials',
      child: Row(
        children: [
          ProgressRing(
            progress: total == 0 ? 0 : online / total,
            color: AppColors.success,
            size: 74,
            stroke: 6,
            celebrate: false,
            center: Text('$online/$total', style: context.hud.number(size: 20)),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('DATA LINKS', style: context.hud.label(size: 11)),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    HudChip(
                      label: '$online online',
                      dot: true,
                      color: AppColors.success,
                    ),
                    // Zero counts are noise; only show what needs action.
                    if (setup > 0)
                      HudChip(
                        label: '$setup to set up',
                        dot: true,
                        color: AppColors.info,
                      ),
                    if (awaiting > 0)
                      HudChip(
                        label: '$awaiting awaiting keys',
                        dot: true,
                        color: AppColors.warning,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tile + sheet
// ---------------------------------------------------------------------------

/// Brand-neutral glyph: a two-letter monogram in a glass badge with a status
/// glow ring.
class _Glyph extends StatelessWidget {
  const _Glyph({required this.text, required this.color, this.status});
  final String text;
  final Color color;
  final IntegrationDisplayStatus? status;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final ring = status?.color ?? hud.textMuted;
    final on = status == IntegrationDisplayStatus.connected;
    return SizedBox.square(
      dimension: 50,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          HudBadge(text: text, color: color, size: 50),
          Positioned(
            right: -3,
            bottom: -3,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ring,
                border: Border.all(
                  color: hud.isDark ? AppColors.darkBg : Colors.white,
                  width: 2,
                ),
                boxShadow: on
                    ? [
                        BoxShadow(
                          color: ring.withValues(alpha: 0.8 * hud.glowStrength),
                          blurRadius: 8,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.glyph,
    required this.title,
    required this.color,
    required this.status,
    required this.row,
    required this.now,
    required this.capabilities,
    required this.onOpen,
    this.primary,
    this.infoChip,
    this.busy = false,
  });

  final String glyph;
  final String title;
  final Color color;
  final IntegrationDisplayStatus? status;
  final IntegrationConnection? row;
  final DateTime now;
  final List<String> capabilities;
  final VoidCallback onOpen;
  final Widget? primary;
  final String? infoChip;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final last = row?.lastSyncAt;
    final connected = status == IntegrationDisplayStatus.connected;
    return AppCard(
      accent: connected ? color : null,
      onTap: onOpen,
      semanticLabel: '$title integration',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Glyph(text: glyph, color: color, status: status),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.titleMedium),
                    const SizedBox(height: 3),
                    if (status != null)
                      StatusChip(status!)
                    else if (infoChip != null)
                      HudTag(infoChip!.toUpperCase(), color: hud.accentInk),
                  ],
                ),
              ),
              if (busy)
                const HudSpinner(size: 22)
              else
                Icon(Icons.chevron_right, color: hud.textMuted),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          for (final c in capabilities.take(2))
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6, right: 8),
                    child: Container(
                      width: 4,
                      height: 4,
                      color: color.withValues(alpha: 0.8),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      c,
                      style: t.bodySmall?.copyWith(color: hud.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          if (last != null || (row?.lastError != null && !connected))
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                row?.lastError != null && !connected
                    ? 'LAST ERROR · ${row!.lastError}'
                    : 'LAST SYNC · ${Fmt.ago(last!.toLocal(), now).toUpperCase()}',
                style: hud.mono(
                  size: 10,
                  color: row?.lastError != null && !connected
                      ? AppColors.danger
                      : hud.textMuted,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (primary != null) ...[
            const SizedBox(height: AppSpacing.md),
            primary!,
          ],
        ],
      ),
    );
  }
}

List<String> _scopes(IntegrationConnection? row) {
  final raw = row?.scopesJson;
  if (raw == null) return const [];
  try {
    return (jsonDecode(raw) as List).map((e) => e.toString()).toList();
  } on FormatException {
    return const [];
  }
}

/// Details sheet: capabilities, notes, scopes, actions and setup steps.
Future<void> _openSheet(
  BuildContext context, {
  required String title,
  required String glyph,
  required Color color,
  required IntegrationDisplayStatus? status,
  required IntegrationConnection? row,
  required DateTime now,
  required List<String> capabilities,
  List<Widget> Function(BuildContext sheet)? actions,
  List<HudStep> setupSteps = const [],
  String? note,
  String? docFile,
}) => showHudBottomSheet<void>(
  context,
  title: title,
  builder: (ctx) {
    final t = Theme.of(ctx).textTheme;
    final hud = ctx.hud;
    final scopes = _scopes(row);
    final acts = actions?.call(ctx) ?? const <Widget>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _Glyph(text: glyph, color: color, status: status),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ?(status == null ? null : StatusChip(status)),
                  const SizedBox(height: 3),
                  Text(
                    row?.lastSyncAt == null
                        ? 'Never synced'
                        : 'Last successful sync '
                              '${Fmt.ago(row!.lastSyncAt!.toLocal(), now)}',
                    style: hud.mono(size: 10.5),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('CAPABILITIES', style: hud.label(size: 11)),
        const SizedBox(height: AppSpacing.sm),
        for (final c in capabilities)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check, size: 15, color: color),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(c, style: t.bodyMedium)),
              ],
            ),
          ),
        if (note != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(note, style: t.bodySmall?.copyWith(color: hud.textMuted)),
        ],
        if (scopes.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Text('GRANTED · ${scopes.join(', ')}', style: hud.mono(size: 10)),
        ],
        if (row?.lastError != null &&
            status != IntegrationDisplayStatus.connected) ...[
          const SizedBox(height: AppSpacing.md),
          NoticeBanner(
            message: 'Last error: ${row!.lastError}',
            color: AppColors.danger,
            icon: Icons.error_outline,
          ),
        ],
        if (acts.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          for (final (i, a) in acts.indexed) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            a,
          ],
        ],
        if (setupSteps.isNotEmpty) ...[
          const HudDivider(height: AppSpacing.xl),
          Text('SETUP', style: hud.label(size: 11)),
          const SizedBox(height: AppSpacing.md),
          HudSteps(steps: setupSteps),
        ],
        if (docFile != null) ...[
          const SizedBox(height: AppSpacing.md),
          Text('DOCS · $docFile', style: hud.mono(size: 10)),
        ],
      ],
    );
  },
);

void _snack(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// Runs [body] with a busy flag; reports the message (or a typed error).
mixin _BusyRunner<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool busy = false;

  Future<void> run(Future<String> Function() body) async {
    setState(() => busy = true);
    try {
      final msg = await body();
      Haptics.success();
      if (mounted) _snack(context, msg);
    } on CancelledException {
      // User backed out; nothing to report.
    } on IntegrationException catch (e) {
      Haptics.warning();
      if (mounted) _snack(context, e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

// ---------------------------------------------------------------------------
// Simple tiles
// ---------------------------------------------------------------------------

class _StaticTile extends StatelessWidget {
  const _StaticTile({
    required this.glyph,
    required this.title,
    required this.color,
    required this.status,
    required this.row,
    required this.now,
    required this.capabilities,
    this.infoChip,
    this.note,
    this.setupSteps = const [],
    this.actionLabel,
    this.onAction,
  });

  final String glyph;
  final String title;
  final Color color;
  final IntegrationDisplayStatus? status;
  final IntegrationConnection? row;
  final DateTime now;
  final List<String> capabilities;
  final String? infoChip;
  final String? note;
  final List<HudStep> setupSteps;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => _Tile(
    glyph: glyph,
    title: title,
    color: color,
    status: status,
    row: row,
    now: now,
    capabilities: capabilities,
    infoChip: infoChip,
    onOpen: () => _openSheet(
      context,
      title: title,
      glyph: glyph,
      color: color,
      status: status,
      row: row,
      now: now,
      capabilities: capabilities,
      note: note,
      setupSteps: setupSteps,
      actions: actionLabel == null
          ? null
          : (sheet) => [
              HudButton.secondary(
                label: actionLabel!,
                expand: true,
                onPressed: () {
                  Navigator.pop(sheet);
                  onAction?.call();
                },
              ),
            ],
    ),
  );
}

class _HealthConnectTile extends StatelessWidget {
  const _HealthConnectTile({required this.row, required this.now});
  final IntegrationConnection? row;
  final DateTime now;

  static const _caps = [
    'Steps, distance, active energy and exercise sessions',
    'Sleep and weight; heart rate when a wearable writes it',
    'Phone-only works: any step counter that writes to Health Connect',
  ];

  @override
  Widget build(BuildContext context) {
    final status = displayStatus(row);
    return _Tile(
      glyph: 'HC',
      title: 'Health Connect',
      color: AppColors.heart,
      status: status,
      row: row,
      now: now,
      capabilities: _caps,
      onOpen: () => context.push(AppPaths.healthStatus),
      primary: status == IntegrationDisplayStatus.connected
          ? null
          : HudButton.secondary(
              label: 'Set up Health Connect',
              icon: Icons.health_and_safety_outlined,
              expand: true,
              compact: true,
              onPressed: () => context.push(AppPaths.healthStatus),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hevy
// ---------------------------------------------------------------------------

class _HevyTile extends ConsumerStatefulWidget {
  const _HevyTile({required this.row, required this.now});
  final IntegrationConnection? row;
  final DateTime now;

  @override
  ConsumerState<_HevyTile> createState() => _HevyTileState();
}

class _HevyTileState extends ConsumerState<_HevyTile>
    with _BusyRunner<_HevyTile> {
  static const _caps = [
    'Imports workouts, exercises and sets (read-only)',
    'Exercise templates for muscle-group mapping',
    'Incremental sync via workout events',
  ];

  Future<void> _enterKey() async {
    final key = await showHudBottomSheet<String>(
      context,
      title: 'Hevy API key',
      builder: (_) => const _HevyKeySheet(),
    );
    if (key == null || key.trim().isEmpty) return;
    await run(() async {
      await ref.read(hevySyncServiceProvider).connect(key);
      final msg = await ref.read(syncControllerProvider.notifier).syncHevy();
      return 'Hevy connected. $msg';
    });
  }

  Future<void> _disconnect() async {
    Haptics.heavy();
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect Hevy?'),
        content: const Text(
          'Your API key will be deleted from this device. Do you want to keep '
          'the workouts already imported from Hevy?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('Delete imported data'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'keep'),
            child: const Text('Keep data'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    await run(() async {
      await ref
          .read(hevySyncServiceProvider)
          .disconnect(deleteData: choice == 'delete');
      return choice == 'delete'
          ? 'Hevy disconnected and imported workouts deleted'
          : 'Hevy disconnected (imported workouts kept)';
    });
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final status = displayStatus(row);
    final connected = status == IntegrationDisplayStatus.connected;
    final syncing = ref.watch(syncControllerProvider).hevy;
    final b = busy || syncing;
    final ctrl = ref.read(syncControllerProvider.notifier);
    return _Tile(
      glyph: 'HV',
      title: 'Hevy',
      color: AppColors.strength,
      status: status,
      row: row,
      now: widget.now,
      capabilities: _caps,
      busy: b,
      primary: connected
          ? HudButton.secondary(
              label: b ? 'Syncing…' : 'Sync now',
              icon: Icons.sync,
              loading: b,
              expand: true,
              compact: true,
              onPressed: b ? null : () => run(ctrl.syncHevy),
            )
          : HudButton(
              label: row == null ? 'Add API key' : 'Reconnect',
              icon: Icons.key,
              expand: true,
              compact: true,
              onPressed: b ? null : _enterKey,
            ),
      onOpen: () => _openSheet(
        context,
        title: 'Hevy',
        glyph: 'HV',
        color: AppColors.strength,
        status: status,
        row: row,
        now: widget.now,
        capabilities: _caps,
        note:
            'Requires Hevy Pro. Your API key is stored only in Android '
            'encrypted storage. No Pro? Use Train → + → Import Hevy CSV.',
        actions: (sheet) => [
          if (connected) ...[
            HudButton.secondary(
              label: 'Test connection',
              icon: Icons.network_check,
              expand: true,
              onPressed: () {
                Navigator.pop(sheet);
                run(() async {
                  await ref.read(hevySyncServiceProvider).testConnection();
                  return 'Hevy connection OK';
                });
              },
            ),
            HudButton.ghost(
              label: 'Change key',
              expand: true,
              onPressed: () {
                Navigator.pop(sheet);
                _enterKey();
              },
            ),
          ] else
            HudButton(
              label: row == null ? 'Add API key' : 'Reconnect',
              icon: Icons.key,
              expand: true,
              onPressed: () {
                Navigator.pop(sheet);
                _enterKey();
              },
            ),
          if (row != null && row.status != ConnectionStates.disconnected)
            HudButton(
              label: 'Disconnect',
              variant: HudButtonVariant.danger,
              expand: true,
              onPressed: () {
                Navigator.pop(sheet);
                _disconnect();
              },
            ),
        ],
        setupSteps: const [
          HudStep('Get Hevy Pro', 'The API is a Hevy Pro feature.'),
          HudStep(
            'Generate a key',
            'Open hevy.com/settings?developer and create an API key.',
          ),
          HudStep(
            'Paste it here',
            'Athlete OS tests it with /v1/user/info before saving.',
          ),
        ],
        docFile: 'docs/integrations/hevy.md',
      ),
    );
  }
}

class _HevyKeySheet extends StatefulWidget {
  const _HevyKeySheet();
  @override
  State<_HevyKeySheet> createState() => _HevyKeySheetState();
}

class _HevyKeySheetState extends State<_HevyKeySheet> {
  final _c = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Hevy\'s API requires a Hevy Pro subscription. Generate a key in '
            'Hevy settings → Developer, then paste it here.',
            style: t.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: HudButton.ghost(
              label: 'Open hevy.com/settings?developer',
              icon: Icons.open_in_new,
              compact: true,
              onPressed: () => launchUrl(
                Uri.parse('https://hevy.com/settings?developer'),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _c,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            style: hud.mono(size: 14, color: hud.text),
            decoration: InputDecoration(
              labelText: 'API key',
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Show key' : 'Hide key',
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          HudButton(
            label: 'Test & save',
            icon: Icons.verified_outlined,
            expand: true,
            onPressed: () => Navigator.pop(context, _c.text.trim()),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Strava
// ---------------------------------------------------------------------------

class _StravaTile extends ConsumerStatefulWidget {
  const _StravaTile({required this.row, required this.now});
  final IntegrationConnection? row;
  final DateTime now;

  @override
  ConsumerState<_StravaTile> createState() => _StravaTileState();
}

class _StravaTileState extends ConsumerState<_StravaTile>
    with _BusyRunner<_StravaTile> {
  static const _caps = [
    'Runs and other activities from the last 90 days',
    'Per-km splits and laps; HR and elevation streams on demand',
    'Cached ≤ 7 days; never shared with AI (Strava API policy)',
  ];

  Future<void> _connect() => run(() async {
    await ref.read(stravaAuthServiceProvider).connect();
    final msg = await ref.read(syncControllerProvider.notifier).syncStrava();
    return 'Strava connected. $msg';
  });

  Future<void> _disconnect() async {
    Haptics.heavy();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect Strava?'),
        content: const Text(
          'Athlete OS will revoke its Strava access and immediately delete '
          'all Strava activities stored on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Disconnect & delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await run(() async {
      await disconnectStrava(
        auth: ref.read(stravaAuthServiceProvider),
        sync: ref.read(stravaSyncServiceProvider),
        status: ref.read(integrationStatusRepositoryProvider),
      );
      return 'Strava disconnected; Strava data deleted';
    });
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final status = displayStatus(row, configured: Env.hasStrava);
    final connected = status == IntegrationDisplayStatus.connected;
    final syncing = ref.watch(syncControllerProvider).strava;
    final b = busy || syncing;
    final ctrl = ref.read(syncControllerProvider.notifier);
    final Widget primary;
    if (!Env.hasStrava) {
      primary = const ConnectWithStravaButton(onPressed: null);
    } else if (connected) {
      primary = HudButton.secondary(
        label: b ? 'Syncing…' : 'Sync now',
        icon: Icons.sync,
        loading: b,
        expand: true,
        compact: true,
        onPressed: b ? null : () => run(ctrl.syncStrava),
      );
    } else {
      primary = ConnectWithStravaButton(onPressed: b ? null : _connect);
    }
    return _Tile(
      glyph: 'ST',
      title: 'Strava',
      color: kStravaOrange,
      status: status,
      row: row,
      now: widget.now,
      capabilities: _caps,
      busy: b,
      primary: primary,
      onOpen: () => _openSheet(
        context,
        title: 'Strava',
        glyph: 'ST',
        color: kStravaOrange,
        status: status,
        row: row,
        now: widget.now,
        capabilities: _caps,
        note: !Env.hasStrava
            ? 'Awaiting credentials: this build has no STRAVA_CLIENT_ID and/or '
                  'Supabase backend, so Strava cannot be connected yet. '
                  'Activity analysis stays rule-based (no AI).'
            : 'Activity analysis is rule-based on this device (no AI).',
        actions: (sheet) => [
          if (row != null && row.status != ConnectionStates.disconnected)
            HudButton(
              label: 'Disconnect & delete Strava data',
              variant: HudButtonVariant.danger,
              expand: true,
              onPressed: () {
                Navigator.pop(sheet);
                _disconnect();
              },
            ),
        ],
        setupSteps: const [
          HudStep(
            'Create a Strava API app',
            'strava.com/settings/api with Authorization Callback Domain '
                '"localhost".',
          ),
          HudStep(
            'Add the IDs to the build',
            'STRAVA_CLIENT_ID, SUPABASE_URL and SUPABASE_ANON_KEY in '
                'config/dev.json.',
          ),
          HudStep(
            'Deploy the token exchange',
            'Apply the strava_tokens migration, deploy the strava-oauth Edge '
                'Function and set its secrets.',
          ),
          HudStep(
            'Rebuild and connect',
            'Build with --dart-define-from-file=config/dev.json, then tap '
                'Connect with Strava.',
          ),
        ],
        docFile: 'docs/integrations/strava.md',
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Google Calendar
// ---------------------------------------------------------------------------

class _GoogleTile extends ConsumerStatefulWidget {
  const _GoogleTile({required this.row, required this.now});
  final IntegrationConnection? row;
  final DateTime now;

  @override
  ConsumerState<_GoogleTile> createState() => _GoogleTileState();
}

class _GoogleTileState extends ConsumerState<_GoogleTile>
    with _BusyRunner<_GoogleTile> {
  static const _caps = [
    'Read events from calendars you select (read-only by default)',
    'Add workout / meal-prep / focus blocks only after you confirm each one',
  ];

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final status = displayStatus(row, configured: Env.hasGoogle);
    final connected = status == IntegrationDisplayStatus.connected;
    final service = ref.read(googleCalendarServiceProvider);
    Widget? primary;
    if (Env.hasGoogle && !connected) {
      primary = HudButton(
        label: row == null ? 'Connect' : 'Reconnect',
        icon: Icons.link,
        expand: true,
        compact: true,
        loading: busy,
        onPressed: busy
            ? null
            : () => run(() async {
                await service.connect();
                return 'Google Calendar connected';
              }),
      );
    } else if (connected) {
      primary = HudButton.secondary(
        label: 'Open calendar',
        icon: Icons.calendar_month,
        expand: true,
        compact: true,
        onPressed: () => context.push(AppPaths.calendar),
      );
    } else {
      primary = HudButton.ghost(
        label: 'Preview your routine timeline',
        icon: Icons.view_timeline_outlined,
        expand: true,
        compact: true,
        onPressed: () => context.push(AppPaths.calendar),
      );
    }
    return _Tile(
      glyph: 'GC',
      title: 'Google Calendar',
      color: AppColors.info,
      status: status,
      row: row,
      now: widget.now,
      capabilities: _caps,
      busy: busy,
      primary: primary,
      onOpen: () => _openSheet(
        context,
        title: 'Google Calendar',
        glyph: 'GC',
        color: AppColors.info,
        status: status,
        row: row,
        now: widget.now,
        capabilities: _caps,
        note: !Env.hasGoogle
            ? 'Awaiting credentials: GOOGLE_WEB_CLIENT_ID is not configured.'
            : 'While the Google OAuth app is in Testing mode, consent expires '
                  'every 7 days and you will need to reconnect.',
        actions: (sheet) => [
          if (connected)
            HudButton.secondary(
              label: 'Test connection',
              icon: Icons.network_check,
              expand: true,
              onPressed: () {
                Navigator.pop(sheet);
                run(() async {
                  final cals = await service.listCalendars();
                  return 'Connection OK · ${cals.length} calendars';
                });
              },
            ),
          if (Env.hasGoogle &&
              row != null &&
              row.status != ConnectionStates.disconnected)
            HudButton(
              label: 'Disconnect',
              variant: HudButtonVariant.danger,
              expand: true,
              onPressed: () {
                Navigator.pop(sheet);
                run(() async {
                  await service.disconnect();
                  return 'Google Calendar disconnected';
                });
              },
            ),
        ],
        setupSteps: const [
          HudStep(
            'Create a Google Cloud project',
            'Enable the Google Calendar API.',
          ),
          HudStep(
            'Configure OAuth consent (Testing)',
            'Add your account as a test user.',
          ),
          HudStep(
            'Android OAuth client',
            'Package com.athleteos.athlete_os + your signing SHA-1.',
          ),
          HudStep(
            'Web OAuth client',
            'Put its ID in config/dev.json as GOOGLE_WEB_CLIENT_ID.',
          ),
        ],
        docFile: 'docs/integrations/google-calendar.md',
      ),
    );
  }
}
