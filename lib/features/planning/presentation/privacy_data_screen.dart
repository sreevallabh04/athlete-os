import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/settings_repository.dart';
import '../data/data_export.dart';
import 'widgets/ui_helpers.dart';

final _consentProvider = StreamProvider.autoDispose.family<bool, String>(
  (ref, key) => ref
      .watch(settingsRepositoryProvider)
      .watch<bool>(key)
      .map((v) => v ?? false),
);

class PrivacyDataScreen extends ConsumerWidget {
  const PrivacyDataScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const AppPage(
      title: 'Privacy & data',
      subtitle: 'Your data lives on this device. You decide what leaves it.',
      children: [
        SectionHeader('Where data lives'),
        _Inventory(),
        SectionHeader('AI consent', subtitle: 'Off by default'),
        _Consents(),
        SectionHeader('Export'),
        _ExportCard(),
        SectionHeader(
          'Delete data',
          subtitle: 'Permanent',
          accent: AppColors.red,
        ),
        _DeleteCard(),
        SectionHeader('Connected services'),
        _ConnectedServices(),
      ],
    );
  }
}

class _Inventory extends StatelessWidget {
  const _Inventory();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget item(IconData icon, String title, String body, Color color) =>
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.titleSmall),
                    const SizedBox(height: 2),
                    Hint(body),
                  ],
                ),
              ),
            ],
          ),
        );
    return AppCard(
      child: Column(
        children: [
          item(
            Icons.phone_android,
            'On this device (private app storage)',
            'Profile and targets, food and water logs, health data synced from '
                'Health Connect, workouts (Hevy/manual), runs (Strava/Health '
                'Connect/manual), habits, mood, journal, tasks, competition '
                'plans, reports, AI conversations and approved coach memory. '
                'Progress photos are stored as files in app storage only.',
            AppColors.success,
          ),
          item(
            Icons.cloud_outlined,
            'Optional backend (only if you set it up)',
            'If you enable the Athlete OS backend, your records may be synced '
                'to your own Supabase project, protected by row-level security. '
                'Progress photos are never uploaded.',
            AppColors.info,
          ),
          item(
            Icons.auto_awesome_outlined,
            'AI coach (only when you use it)',
            'Requests go through the backend to the AI provider you choose. '
                'Health data, journal text and meal photos are included only if '
                'you switch on the matching consent below. Strava data is never '
                'sent to AI.',
            AppColors.cyan,
          ),
          item(
            Icons.block,
            'Never',
            'No advertising, no analytics or crash reporting containing health '
                'data, and no selling or sharing of your data.',
            AppColors.danger,
          ),
        ],
      ),
    );
  }
}

class _Consents extends ConsumerWidget {
  const _Consents();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget toggle(String key, String title, String subtitle) {
      final value = ref.watch(_consentProvider(key)).value ?? false;
      return SwitchListTile(
        value: value,
        title: Text(title),
        subtitle: Text(subtitle),
        onChanged: (v) => ref.read(settingsRepositoryProvider).set(key, v),
      );
    }

    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        children: [
          toggle(
            SettingKeys.aiHealthConsent,
            'Share health & fitness data with AI',
            'Steps, sleep, heart rate, weight, workouts and nutrition '
                'summaries may be included in coach requests. Strava data is '
                'always excluded.',
          ),
          const Divider(height: 1),
          toggle(
            SettingKeys.aiJournalConsent,
            'Share journal text with AI',
            'Journal entries may be used by the coach. Off means journal text '
                'never leaves the device for AI.',
          ),
          const Divider(height: 1),
          toggle(
            SettingKeys.aiPhotoConsent,
            'Send meal photos to AI',
            'Meal photos may be sent for food recognition. Progress photos are '
                'never sent, whatever this setting.',
          ),
        ],
      ),
    );
  }
}

class _ExportCard extends ConsumerStatefulWidget {
  const _ExportCard();

  @override
  ConsumerState<_ExportCard> createState() => _ExportCardState();
}

class _ExportCardState extends ConsumerState<_ExportCard> {
  bool _busy = false;

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final json = await ref.read(dataExportServiceProvider).exportAllJson();
      final date = LocalDates.key(ref.read(clockProvider).now());
      final name = 'athlete_os_export_$date.json';
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              utf8.encode(json),
              mimeType: 'application/json',
              name: name,
            ),
          ],
          fileNameOverrides: [name],
          subject: 'Athlete OS data export',
        ),
      );
    } catch (_) {
      if (mounted) showSnack(context, 'Export failed.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardTitle(
            icon: Icons.download_outlined,
            title: 'Export all my data',
          ),
          const SizedBox(height: AppSpacing.sm),
          const Hint(
            'One JSON file with every table (progress photo images are not '
            'included, only their dates). You choose where to share or save it. '
            'Per-dataset CSV exports are on the Reports screen.',
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _export,
            icon: const Icon(Icons.ios_share),
            label: Text(_busy ? 'Preparing…' : 'Export JSON'),
          ),
        ],
      ),
    );
  }
}

class _DeleteCard extends ConsumerWidget {
  const _DeleteCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        children: [
          for (final c in DeleteCategory.values) ...[
            if (c != DeleteCategory.values.first) const Divider(height: 1),
            ListTile(
              leading: Icon(
                c == DeleteCategory.everything
                    ? Icons.delete_forever
                    : Icons.delete_outline,
                color: AppColors.danger,
              ),
              title: Text(
                c == DeleteCategory.everything
                    ? 'Delete everything'
                    : 'Delete ${c.label.toLowerCase()}',
                style: c == DeleteCategory.everything
                    ? const TextStyle(
                        color: AppColors.danger,
                        fontWeight: FontWeight.w600,
                      )
                    : null,
              ),
              subtitle: Text(_explain(c)),
              onTap: () async {
                final ok = await confirmTyped(
                  context,
                  title: c == DeleteCategory.everything
                      ? 'Delete everything?'
                      : 'Delete ${c.label.toLowerCase()}?',
                  message:
                      '${_explain(c)} This cannot be undone. Consider exporting '
                      'first.',
                );
                if (!ok) return;
                try {
                  await ref.read(dataExportServiceProvider).deleteCategory(c);
                  if (context.mounted) showSnack(context, '${c.label} deleted');
                } catch (_) {
                  if (context.mounted) showSnack(context, 'Delete failed.');
                }
              },
            ),
          ],
        ],
      ),
    );
  }

  static String _explain(DeleteCategory c) => switch (c) {
    DeleteCategory.journal => 'Removes all journal entries from this device.',
    DeleteCategory.mood => 'Removes all mood check-ins.',
    DeleteCategory.progressPhotos =>
      'Deletes every progress photo file and its record.',
    DeleteCategory.aiData =>
      'Removes AI conversations, coach memory, recommendations and the AI '
          'activity log.',
    DeleteCategory.nutrition => 'Removes every food log and water log entry.',
    DeleteCategory.everything =>
      'Wipes all data on this device and resets your profile to example '
          'targets. Connected services keep their own copies.',
  };
}

class _ConnectedServices extends StatelessWidget {
  const _ConnectedServices();

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final services = <(String, String, String)>[
      (
        'Strava',
        'Revoke Athlete OS under My Apps in Strava settings. Imported Strava '
            'data is deleted here within 30 days of disconnecting.',
        'https://www.strava.com/settings/apps',
      ),
      (
        'Hevy',
        'Revoke or rotate your Hevy API key in Hevy settings.',
        'https://hevy.com/settings?developer',
      ),
      (
        'Google (Calendar)',
        'Remove Athlete OS from third-party access in your Google Account.',
        'https://myaccount.google.com/connections',
      ),
      (
        'Health Connect',
        'Manage or revoke permissions in Android Settings → Health Connect.',
        'https://support.google.com/android/answer/12201227',
      ),
    ];
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              0,
            ),
            child: Hint(
              'Deleting data here does not delete it from connected services — '
              'they keep their own copies under their own policies.',
            ),
          ),
          for (final (name, body, url) in services)
            ListTile(
              title: Text(name),
              subtitle: Text(body),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () => _open(url),
            ),
        ],
      ),
    );
  }
}
