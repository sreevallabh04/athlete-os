import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/profile_repository.dart';
import '../../../data/repositories/settings_repository.dart';
import 'widgets/ui_helpers.dart';

/// App version shown in About (kept in sync with pubspec.yaml).
const appVersion = '1.0.0 (1)';

final _hapticsSettingProvider = StreamProvider.autoDispose<bool>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watch<bool>(Haptics.settingKey)
      .map((v) => v ?? true),
);

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeSettingProvider).value ?? 'dark';
    final haptics = ref.watch(_hapticsSettingProvider).value ?? true;
    final settings = ref.read(settingsRepositoryProvider);
    SettingsTile link(IconData icon, String title, String sub, String path) =>
        SettingsTile(
          icon: icon,
          title: title,
          subtitle: sub,
          onTap: () => context.push(path),
        );
    return AppPage(
      title: 'Settings',
      eyebrow: 'ATHLETE OS · v$appVersion',
      children: [
        const _IdentityCard(),
        const SectionHeader('You'),
        SettingsGroup(
          children: [
            link(
              Icons.person_outline,
              'Profile & goals',
              'Targets, diet, schedule, injuries',
              AppPaths.profile,
            ),
            link(
              Icons.blur_on,
              'Recalibrate JARVIS',
              'Targets, program and routine',
              AppPaths.onboarding,
            ),
            link(
              Icons.notifications_none,
              'Notifications',
              'Reminders, quiet hours',
              AppPaths.notificationSettings,
            ),
          ],
        ),
        const SectionHeader('Assistant & AI'),
        SettingsGroup(
          children: [
            link(
              Icons.forum_outlined,
              'Assistant',
              'Triage, reply drafts, approvals',
              AppPaths.assistant,
            ),
            link(
              Icons.verified_user_outlined,
              'Permissions & capabilities',
              'What JARVIS can do on this phone',
              AppPaths.capabilities,
            ),
            link(
              Icons.auto_awesome_outlined,
              'AI providers',
              'Choose and configure the coach model',
              AppPaths.aiSettings,
            ),
            link(
              Icons.psychology_outlined,
              'Coach memory',
              'Facts you approved for the coach',
              AppPaths.aiMemory,
            ),
            link(
              Icons.history,
              'AI activity log',
              'Every action the coach took',
              AppPaths.aiHistory,
            ),
          ],
        ),
        const SectionHeader('Data'),
        SettingsGroup(
          children: [
            link(
              Icons.hub_outlined,
              'Integrations',
              'Health Connect, Hevy, Strava, Google Calendar',
              AppPaths.integrations,
            ),
            link(
              Icons.shield_outlined,
              'Privacy & data',
              'Consents, export, delete',
              AppPaths.privacy,
            ),
          ],
        ),
        const SectionHeader('Experience'),
        SettingsGroup(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const _TileIcon(Icons.palette_outlined),
                      const SizedBox(width: AppSpacing.md),
                      Text(
                        'Theme',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SegmentedHud<String>(
                    segments: const [
                      HudSegment(
                        value: 'dark',
                        label: 'Dark',
                        icon: Icons.dark_mode_outlined,
                      ),
                      HudSegment(
                        value: 'light',
                        label: 'Light',
                        icon: Icons.light_mode_outlined,
                      ),
                      HudSegment(
                        value: 'system',
                        label: 'Auto',
                        icon: Icons.brightness_auto_outlined,
                      ),
                    ],
                    value: mode,
                    onChanged: (v) => settings.set(SettingKeys.themeMode, v),
                  ),
                ],
              ),
            ),
            SettingsTile(
              icon: Icons.vibration,
              title: 'Haptics',
              subtitle: 'Taps, confirmations and goal pulses',
              trailing: HudToggle(
                value: haptics,
                semanticLabel: 'Haptics',
                onChanged: (v) {
                  settings.set(Haptics.settingKey, v);
                  if (v) {
                    Haptics.enabled = true;
                    Haptics.success();
                  }
                },
              ),
            ),
          ],
        ),
        const SectionHeader('About'),
        SettingsGroup(
          children: [
            const SettingsTile(
              icon: Icons.info_outline,
              title: 'Athlete OS',
              subtitle: 'Version $appVersion',
            ),
            SettingsTile(
              icon: Icons.description_outlined,
              title: 'Open-source licenses',
              subtitle: 'Libraries and fonts used by this app',
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Athlete OS',
                applicationVersion: appVersion,
              ),
            ),
            if (kDebugMode)
              SettingsTile(
                icon: Icons.grid_view_outlined,
                title: 'Design gallery',
                subtitle: 'Debug builds only: every HUD component',
                onTap: () => context.push(AppPaths.devGallery),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        const _Attributions(),
      ],
    );
  }
}

class _IdentityCard extends ConsumerWidget {
  const _IdentityCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final p = ref.watch(profileProvider).value;
    final name = p?.displayName?.trim();
    return AppCard(
      brackets: true,
      onTap: () => context.push(AppPaths.profile),
      semanticLabel: 'Profile and goals',
      child: Row(
        children: [
          const AthleteEmblem(size: 52, semanticLabel: null),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name == null || name.isEmpty ? 'Athlete' : name,
                  style: t.titleLarge?.copyWith(fontFamily: AppFonts.display),
                ),
                const SizedBox(height: 2),
                Text(
                  p == null
                      ? 'Loading profile…'
                      : '${Fmt.integer(p.calorieTarget)} kcal · '
                            '${p.proteinTargetG.round()} g P · '
                            '${(p.stepGoal / 1000).toStringAsFixed(p.stepGoal % 1000 == 0 ? 0 : 1)}k steps',
                  style: hud.mono(size: 10.5),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: hud.textMuted),
        ],
      ),
    );
  }
}

/// A glass group of settings rows separated by hairlines.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.only(left: 64),
                child: Divider(
                  height: 1,
                  color: hud.hairline.withValues(alpha: 0.12),
                ),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _TileIcon extends StatelessWidget {
  const _TileIcon(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.sm),
        color: hud.accent.withValues(alpha: 0.10),
        border: Border.all(color: hud.accent.withValues(alpha: 0.28)),
      ),
      child: Icon(icon, size: 18, color: hud.accentInk),
    );
  }
}

/// One settings row: icon badge, title, subtitle, chevron or [trailing].
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: onTap != null,
      label: subtitle == null ? title : '$title. $subtitle',
      excludeSemantics: trailing == null,
      onTap: trailing == null ? onTap : null,
      child: PressableScale(
        onTap: onTap,
        pressedScale: 0.98,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm + 2,
            ),
            child: Row(
              children: [
                _TileIcon(icon),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: t.titleSmall),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: t.bodySmall?.copyWith(color: hud.textMuted),
                        ),
                    ],
                  ),
                ),
                if (trailing != null)
                  trailing!
                else if (onTap != null)
                  Icon(Icons.chevron_right, color: hud.textMuted),
              ],
            ),
          ),
        ),
      ),
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
          HudButton.ghost(
            compact: true,
            label: 'openfoodfacts.org',
            onPressed: () => _open('https://world.openfoodfacts.org'),
          ),
          const SizedBox(height: AppSpacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
          const SizedBox(height: AppSpacing.xs),
          const Hint(
            'Activities imported from Strava are shown with a Strava label, '
            'are never sent to AI providers, and are refreshed or removed '
            'within 7 days.',
          ),
          const SizedBox(height: AppSpacing.md),
          Text('USDA FoodData Central', style: t.titleSmall),
          const Hint(
            'Nutrient data from the U.S. Department of Agriculture (public domain).',
          ),
          const SizedBox(height: AppSpacing.md),
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
