import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/settings_repository.dart';
import 'widgets/ui_helpers.dart';

/// App version shown in About (kept in sync with pubspec.yaml).
const appVersion = '1.0.0 (1)';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeSettingProvider).value ?? 'dark';
    Widget link(
      IconData icon,
      String title,
      String sub,
      String path,
      Color c,
    ) => _SettingsTile(
      icon: icon,
      color: c,
      title: title,
      subtitle: sub,
      onTap: () => context.push(path),
    );
    return AppPage(
      title: 'Settings',
      children: [
        const SectionHeader('You'),
        _Group(
          children: [
            link(
              Icons.person_outline,
              'Profile & goals',
              'Targets, diet, schedule, injuries',
              AppPaths.profile,
              AppColors.brand,
            ),
            link(
              Icons.notifications_none,
              'Notifications',
              'Reminders, quiet hours',
              AppPaths.notificationSettings,
              AppColors.warning,
            ),
          ],
        ),
        const SectionHeader('Connections & AI'),
        _Group(
          children: [
            link(
              Icons.hub_outlined,
              'Integrations',
              'Health Connect, Hevy, Strava, Google Calendar',
              AppPaths.integrations,
              AppColors.brandAlt,
            ),
            link(
              Icons.auto_awesome_outlined,
              'AI providers',
              'Choose and configure the coach model',
              AppPaths.aiSettings,
              AppColors.competition,
            ),
            link(
              Icons.psychology_outlined,
              'Coach memory',
              'What the coach remembers (you approve every item)',
              AppPaths.aiMemory,
              AppColors.sleep,
            ),
            link(
              Icons.history,
              'AI activity log',
              'Every action the coach took',
              AppPaths.aiHistory,
              AppColors.info,
            ),
          ],
        ),
        const SectionHeader('Privacy'),
        _Group(
          children: [
            link(
              Icons.shield_outlined,
              'Privacy & data',
              'Consents, export, delete',
              AppPaths.privacy,
              AppColors.success,
            ),
          ],
        ),
        const SectionHeader('Appearance'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const CardTitle(icon: Icons.palette_outlined, title: 'Theme'),
              const SizedBox(height: AppSpacing.md),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'dark',
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode_outlined),
                  ),
                  ButtonSegment(
                    value: 'light',
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode_outlined),
                  ),
                  ButtonSegment(
                    value: 'system',
                    label: Text('System'),
                    icon: Icon(Icons.brightness_auto_outlined),
                  ),
                ],
                selected: {mode},
                onSelectionChanged: (s) => ref
                    .read(settingsRepositoryProvider)
                    .set(SettingKeys.themeMode, s.first),
              ),
            ],
          ),
        ),
        const SectionHeader('About'),
        _Group(
          children: [
            const _SettingsTile(
              icon: Icons.info_outline,
              color: AppColors.info,
              title: 'Athlete OS',
              subtitle: 'Version $appVersion',
            ),
            _SettingsTile(
              icon: Icons.description_outlined,
              color: AppColors.info,
              title: 'Open-source licenses',
              subtitle: 'Libraries used by this app',
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Athlete OS',
                applicationVersion: appVersion,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        const _Attributions(),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 64),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    this.onTap,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minVerticalPadding: 12,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: onTap == null ? null : const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _Attributions extends StatelessWidget {
  const _Attributions();

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CardTitle(
            icon: Icons.handshake_outlined,
            title: 'Data attributions',
          ),
          const SizedBox(height: AppSpacing.md),
          Text('Open Food Facts', style: t.titleSmall),
          const Hint(
            'Food data from Open Food Facts, available under the Open '
            'Database License (ODbL). Individual contents under the Database '
            'Contents License.',
          ),
          TextButton(
            onPressed: () => _open('https://world.openfoodfacts.org'),
            child: const Text('openfoodfacts.org'),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: const BoxDecoration(
                  color: AppColors.running,
                  borderRadius: AppRadii.chip,
                ),
                child: Text(
                  'Powered by Strava',
                  style: t.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          const Hint(
            'Activities imported from Strava are shown with a Strava label, '
            'are never sent to AI providers, and are refreshed or removed '
            'within 7 days.',
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('USDA FoodData Central', style: t.titleSmall),
          const Hint(
            'Nutrient data from the U.S. Department of Agriculture (public domain).',
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('Hevy · Health Connect · Google Calendar', style: t.titleSmall),
          const Hint(
            'Data from connected services belongs to you and remains subject '
            'to each service’s terms.',
          ),
        ],
      ),
    );
  }
}
