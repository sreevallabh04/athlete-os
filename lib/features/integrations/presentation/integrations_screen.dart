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
import '../../train/presentation/widgets/strava_branding.dart';
import '../../train/presentation/widgets/sync_status.dart';
import '../data/api_errors.dart';
import '../data/google_calendar_service.dart';

class IntegrationsScreen extends ConsumerWidget {
  const IntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(integrationStatusesProvider).value ?? const [];
    IntegrationConnection? row(String p) =>
        rows.where((r) => r.provider == p).firstOrNull;
    final now = ref.watch(clockProvider).now();
    return AppPage(
      title: 'Integrations',
      subtitle:
          'Official APIs only. Status shows "Connected" only after a real '
          'successful call.',
      children: spaced([
        _HevyCard(row: row(Providers.hevy), now: now),
        _StravaCard(row: row(Providers.strava), now: now),
        _GoogleCard(row: row(Providers.googleCalendar), now: now),
        _IntegrationCard(
          title: 'Health Connect',
          icon: Icons.favorite,
          color: AppColors.heart,
          status: displayStatus(row(Providers.healthConnect)),
          row: row(Providers.healthConnect),
          now: now,
          capabilities: const [
            'Steps, distance, active minutes',
            'Heart rate, resting HR, sleep, weight',
            'Exercise sessions (runs from Samsung Health / watches)',
          ],
          actions: [
            FilledButton.tonal(
              onPressed: () => context.push(AppPaths.healthStatus),
              child: const Text('Open Health Connect status'),
            ),
          ],
          setupSteps: const [
            'Install/update Health Connect (built into Android 14+).',
            'Open Health Connect status and grant the requested permissions.',
            'In Samsung Health: Settings → Health Connect → allow sharing.',
          ],
          docFile: 'Health Connect status screen',
        ),
        _IntegrationCard(
          title: 'Samsung Health',
          icon: Icons.watch,
          color: AppColors.steps,
          status: displayStatus(row(Providers.healthConnect)),
          row: null,
          now: now,
          capabilities: const [
            'Read via Health Connect (steps, sleep, heart rate, workouts)',
          ],
          note:
              'There is no direct Samsung Health API without a Samsung '
              'partnership, so Athlete OS reads Samsung data through Health '
              'Connect. Status mirrors Health Connect.',
          setupSteps: const [
            'Samsung Health → Settings → Health Connect → turn on sync.',
            'Grant Athlete OS access in Health Connect.',
          ],
        ),
        _IntegrationCard(
          title: 'AI providers',
          icon: Icons.auto_awesome,
          color: AppColors.brand,
          status: displayStatus(row(Providers.aiBackend)),
          row: row(Providers.aiBackend),
          now: now,
          capabilities: const [
            'AI coach chat, meal estimates, weekly insights',
            'Never receives Strava data (Strava API policy)',
          ],
          actions: [
            FilledButton.tonal(
              onPressed: () => context.push(AppPaths.aiSettings),
              child: const Text('AI provider settings'),
            ),
          ],
        ),
        _IntegrationCard(
          title: 'Open Food Facts',
          icon: Icons.qr_code_scanner,
          color: AppColors.protein,
          status: row(Providers.openFoodFacts) == null
              ? null
              : displayStatus(row(Providers.openFoodFacts)),
          infoChip: 'No account needed',
          row: row(Providers.openFoodFacts),
          now: now,
          capabilities: const ['Barcode lookup', 'Food search'],
          note:
              'Data © Open Food Facts contributors, available under the Open '
              'Database License (ODbL).',
        ),
        _IntegrationCard(
          title: 'USDA FoodData Central',
          icon: Icons.restaurant_menu,
          color: AppColors.carbs,
          status: Env.usdaApiKey.isEmpty
              ? IntegrationDisplayStatus.awaitingCredentials
              : displayStatus(row(Providers.usda)),
          row: row(Providers.usda),
          now: now,
          capabilities: const ['Generic food nutrient data (public domain)'],
          note: 'Optional. Provide a free api.data.gov key via build config.',
          setupSteps: const [
            'Get a key at https://fdc.nal.usda.gov/api-key-signup.html',
            'Add "USDA_API_KEY" to config/dev.json and rebuild.',
          ],
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Generic card
// ---------------------------------------------------------------------------

class _IntegrationCard extends StatelessWidget {
  const _IntegrationCard({
    required this.title,
    required this.icon,
    required this.color,
    required this.status,
    required this.row,
    required this.now,
    this.capabilities = const [],
    this.actions = const [],
    this.setupSteps = const [],
    this.docFile,
    this.note,
    this.infoChip,
  });

  final String title;
  final IconData icon;
  final Color color;
  final IntegrationDisplayStatus? status;
  final IntegrationConnection? row;
  final DateTime now;
  final List<String> capabilities;
  final List<Widget> actions;
  final List<String> setupSteps;
  final String? docFile;
  final String? note;
  final String? infoChip;

  List<String> get _scopes {
    final raw = row?.scopesJson;
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List).map((e) => e.toString()).toList();
    } on FormatException {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final muted = t.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final scopes = _scopes;
    return AppCard(
      semanticLabel: '$title integration',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: Text(title, style: t.titleMedium)),
              if (status != null)
                StatusChip(status!)
              else if (infoChip != null)
                Chip(
                  label: Text(infoChip!),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          if (capabilities.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            for (final c in capabilities)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text('• $c', style: t.bodyMedium),
              ),
          ],
          if (note != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(note!, style: muted),
          ],
          if (scopes.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text('Granted: ${scopes.join(', ')}', style: muted),
          ],
          if (row?.lastSyncAt != null)
            Text(
              'Last successful sync: ${Fmt.ago(row!.lastSyncAt!.toLocal(), now)}',
              style: muted,
            ),
          if (row?.lastError != null &&
              status != IntegrationDisplayStatus.connected)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                'Last error: ${row!.lastError}',
                style: t.bodySmall?.copyWith(color: AppColors.danger),
              ),
            ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: actions,
            ),
          ],
          if (setupSteps.isNotEmpty || docFile != null)
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                title: Text('Setup steps', style: t.labelLarge),
                children: [
                  for (var i = 0; i < setupSteps.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${i + 1}. ${setupSteps[i]}',
                        style: t.bodySmall,
                      ),
                    ),
                  if (docFile != null)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      child: Text('Docs: $docFile', style: muted),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

void _snack(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

// ---------------------------------------------------------------------------
// Hevy
// ---------------------------------------------------------------------------

class _HevyCard extends ConsumerStatefulWidget {
  const _HevyCard({required this.row, required this.now});
  final IntegrationConnection? row;
  final DateTime now;

  @override
  ConsumerState<_HevyCard> createState() => _HevyCardState();
}

class _HevyCardState extends ConsumerState<_HevyCard> {
  bool _busy = false;

  Future<void> _run(Future<String> Function() body) async {
    setState(() => _busy = true);
    try {
      final msg = await body();
      if (mounted) _snack(context, msg);
    } on IntegrationException catch (e) {
      if (mounted) _snack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enterKey() async {
    final key = await showDialog<String>(
      context: context,
      builder: (_) => const _HevyKeyDialog(),
    );
    if (key == null || key.trim().isEmpty) return;
    await _run(() async {
      await ref.read(hevySyncServiceProvider).connect(key);
      final msg = await ref.read(syncControllerProvider.notifier).syncHevy();
      return 'Hevy connected. $msg';
    });
  }

  Future<void> _disconnect() async {
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
    await _run(() async {
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
    return _IntegrationCard(
      title: 'Hevy',
      icon: Icons.fitness_center,
      color: AppColors.strength,
      status: status,
      row: row,
      now: widget.now,
      capabilities: const [
        'Imports workouts, exercises and sets (read-only)',
        'Exercise templates for muscle-group mapping',
        'Incremental sync via workout events',
      ],
      note:
          'Requires Hevy Pro. Your API key is stored only in Android '
          'encrypted storage.',
      actions: [
        if (_busy || syncing)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.sm),
            child: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else ...[
          if (!connected)
            FilledButton(
              onPressed: _enterKey,
              child: Text(row == null ? 'Add API key' : 'Reconnect'),
            ),
          if (connected) ...[
            FilledButton.tonal(
              onPressed: () =>
                  _run(ref.read(syncControllerProvider.notifier).syncHevy),
              child: const Text('Sync now'),
            ),
            OutlinedButton(
              onPressed: () => _run(() async {
                await ref.read(hevySyncServiceProvider).testConnection();
                return 'Hevy connection OK';
              }),
              child: const Text('Test connection'),
            ),
            OutlinedButton(
              onPressed: _enterKey,
              child: const Text('Change key'),
            ),
          ],
          if (row != null && row.status != ConnectionStates.disconnected)
            TextButton(onPressed: _disconnect, child: const Text('Disconnect')),
        ],
      ],
      setupSteps: const [
        'Subscribe to Hevy Pro (the API is a Pro feature).',
        'Open https://hevy.com/settings?developer and generate an API key.',
        'Tap "Add API key" and paste it. The app tests it with /v1/user/info.',
        'No Pro? Export CSV in Hevy and use Train → + → Import Hevy CSV.',
      ],
      docFile: 'docs/integrations/hevy.md',
    );
  }
}

class _HevyKeyDialog extends StatefulWidget {
  const _HevyKeyDialog();
  @override
  State<_HevyKeyDialog> createState() => _HevyKeyDialogState();
}

class _HevyKeyDialogState extends State<_HevyKeyDialog> {
  final _c = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Hevy API key'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Hevy\'s API requires a Hevy Pro subscription. Generate a key in '
            'Hevy settings → Developer, then paste it here.',
          ),
          TextButton.icon(
            onPressed: () => launchUrl(
              Uri.parse('https://hevy.com/settings?developer'),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Open hevy.com/settings?developer'),
          ),
          TextField(
            controller: _c,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API key',
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Show key' : 'Hide key',
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _c.text.trim()),
          child: const Text('Test & save'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Strava
// ---------------------------------------------------------------------------

class _StravaCard extends ConsumerStatefulWidget {
  const _StravaCard({required this.row, required this.now});
  final IntegrationConnection? row;
  final DateTime now;

  @override
  ConsumerState<_StravaCard> createState() => _StravaCardState();
}

class _StravaCardState extends ConsumerState<_StravaCard> {
  bool _busy = false;

  Future<void> _run(Future<String> Function() body) async {
    setState(() => _busy = true);
    try {
      final msg = await body();
      if (mounted) _snack(context, msg);
    } on IntegrationException catch (e) {
      if (mounted) _snack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
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
    await _run(() async {
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
    return _IntegrationCard(
      title: 'Strava',
      icon: Icons.directions_run,
      color: kStravaOrange,
      status: status,
      row: row,
      now: widget.now,
      capabilities: const [
        'Runs and other activities from the last 90 days',
        'Per-km splits, laps; HR and elevation streams on demand',
        'Cached ≤ 7 days; never shared with AI (Strava API policy)',
      ],
      note: !Env.hasStrava
          ? 'Awaiting credentials: this build has no STRAVA_CLIENT_ID and/or '
                'Supabase backend, so Strava cannot be connected yet.'
          : null,
      actions: [
        if (!Env.hasStrava)
          const ConnectWithStravaButton(onPressed: null)
        else if (_busy || syncing)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.sm),
            child: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else ...[
          if (!connected)
            ConnectWithStravaButton(
              onPressed: () => _run(() async {
                await ref.read(stravaAuthServiceProvider).connect();
                final msg = await ref
                    .read(syncControllerProvider.notifier)
                    .syncStrava();
                return 'Strava connected. $msg';
              }),
            ),
          if (connected)
            FilledButton.tonal(
              onPressed: () =>
                  _run(ref.read(syncControllerProvider.notifier).syncStrava),
              child: const Text('Sync now'),
            ),
          if (row != null && row.status != ConnectionStates.disconnected)
            TextButton(onPressed: _disconnect, child: const Text('Disconnect')),
        ],
      ],
      setupSteps: const [
        'Create an API app at https://www.strava.com/settings/api with '
            'Authorization Callback Domain "localhost".',
        'Add STRAVA_CLIENT_ID, SUPABASE_URL and SUPABASE_ANON_KEY to '
            'config/dev.json.',
        'Apply the strava_tokens migration and deploy the strava-oauth Edge '
            'Function.',
        'supabase secrets set STRAVA_CLIENT_ID=… STRAVA_CLIENT_SECRET=…',
        'Rebuild with --dart-define-from-file=config/dev.json and tap '
            'Connect with Strava.',
      ],
      docFile: 'docs/integrations/strava.md',
    );
  }
}

// ---------------------------------------------------------------------------
// Google Calendar
// ---------------------------------------------------------------------------

class _GoogleCard extends ConsumerStatefulWidget {
  const _GoogleCard({required this.row, required this.now});
  final IntegrationConnection? row;
  final DateTime now;

  @override
  ConsumerState<_GoogleCard> createState() => _GoogleCardState();
}

class _GoogleCardState extends ConsumerState<_GoogleCard> {
  bool _busy = false;

  Future<void> _run(Future<String> Function() body) async {
    setState(() => _busy = true);
    try {
      final msg = await body();
      if (mounted) _snack(context, msg);
    } on CancelledException {
      // User backed out; nothing to report.
    } on IntegrationException catch (e) {
      if (mounted) _snack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final status = displayStatus(row, configured: Env.hasGoogle);
    final connected = status == IntegrationDisplayStatus.connected;
    final service = ref.read(googleCalendarServiceProvider);
    return _IntegrationCard(
      title: 'Google Calendar',
      icon: Icons.calendar_month,
      color: AppColors.info,
      status: status,
      row: row,
      now: widget.now,
      capabilities: const [
        'Read events from calendars you select (read-only by default)',
        'Create workout / meal-prep / focus / habit blocks only after you '
            'confirm each one',
      ],
      note: !Env.hasGoogle
          ? 'Awaiting credentials: GOOGLE_WEB_CLIENT_ID is not configured.'
          : 'While the Google OAuth app is in Testing mode, consent expires '
                'every 7 days and you will need to reconnect.',
      actions: [
        if (Env.hasGoogle && _busy)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.sm),
            child: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (Env.hasGoogle) ...[
          if (!connected)
            FilledButton(
              onPressed: () => _run(() async {
                await service.connect();
                return 'Google Calendar connected';
              }),
              child: Text(row == null ? 'Connect' : 'Reconnect'),
            ),
          if (connected) ...[
            FilledButton.tonal(
              onPressed: () => context.push(AppPaths.calendar),
              child: const Text('Open calendar'),
            ),
            OutlinedButton(
              onPressed: () => _run(() async {
                final cals = await service.listCalendars();
                return 'Connection OK · ${cals.length} calendars';
              }),
              child: const Text('Test connection'),
            ),
          ],
          if (row != null && row.status != ConnectionStates.disconnected)
            TextButton(
              onPressed: () => _run(() async {
                await service.disconnect();
                return 'Google Calendar disconnected';
              }),
              child: const Text('Disconnect'),
            ),
        ],
      ],
      setupSteps: const [
        'Create a Google Cloud project and enable the Google Calendar API.',
        'Configure the OAuth consent screen (Testing) and add your account '
            'as a test user.',
        'Create an Android OAuth client: package com.athleteos.athlete_os + '
            'your signing SHA-1.',
        'Create a Web OAuth client; put its ID in config/dev.json as '
            'GOOGLE_WEB_CLIENT_ID.',
      ],
      docFile: 'docs/integrations/google-calendar.md',
    );
  }
}
