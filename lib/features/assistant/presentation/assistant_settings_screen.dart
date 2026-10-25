import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../application/providers.dart';
import '../application/reply_drafter.dart';
import '../data/assistant_platform.dart';
import '../domain/assistant_models.dart';
import '../domain/assistant_settings.dart';
import '../domain/reply_policy_engine.dart';
import 'widgets/assistant_widgets.dart';

class AssistantSettingsScreen extends ConsumerWidget {
  const AssistantSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(assistantSettingsProvider);
    return AppPage(
      title: 'Messaging assistant',
      eyebrow: 'COMMS · RULES OF ENGAGEMENT',
      subtitle:
          'Everything is off until you enable it. Rules are enforced '
          'in code, not by AI.',
      actions: [
        IconButton(
          tooltip: 'Permissions & capabilities',
          icon: const Icon(Icons.verified_user_outlined),
          onPressed: () => context.push(AppPaths.capabilities),
        ),
      ],
      children: [
        settings.when(
          loading: () => const LoadingState(),
          error: (e, _) =>
              const ErrorState(message: 'Could not load settings.'),
          data: (s) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const KillSwitchCard(),
              const SectionHeader('Global mode'),
              _ModeCard(settings: s),
              const SectionHeader(
                'Apps',
                subtitle: 'Only enabled apps are read. All start off.',
              ),
              const _AppsSection(),
              const SectionHeader(
                'Conversations',
                subtitle: 'Approve or block chats; set tone per contact.',
              ),
              const _ConversationsSection(),
              const SectionHeader(
                'Restricted auto-reply limits',
                subtitle: 'Only used in Restricted auto-reply mode.',
              ),
              _LimitsCard(limits: s.limits),
              const SectionHeader('Your tone'),
              _ToneCard(tone: s.tone),
              const SectionHeader('AI'),
              _AiCard(settings: s),
              const SectionHeader('Briefings & background'),
              _BriefingCard(settings: s),
              const SectionHeader('Data'),
              _DataCard(settings: s),
            ],
          ),
        ),
      ],
    );
  }
}

class _ModeCard extends ConsumerWidget {
  const _ModeCard({required this.settings});
  final AssistantSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        children: [
          for (final m in const [
            AssistantMode.observe,
            AssistantMode.draft,
            AssistantMode.approval,
            AssistantMode.restrictedAuto,
            AssistantMode.disabled,
          ])
            _ModeOption(
              mode: m,
              selected: settings.mode == m,
              onTap: () {
                Haptics.selection();
                ref.read(assistantControllerProvider).setMode(m);
              },
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Text(
              'Each app can be set lower, never higher, than this mode.',
              style: t.bodySmall?.copyWith(color: hud.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({
    required this.mode,
    required this.selected,
    required this.onTap,
  });
  final AssistantMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    final c = mode == AssistantMode.restrictedAuto
        ? AppColors.warning
        : mode == AssistantMode.disabled
        ? hud.textMuted
        : hud.accent;
    return Semantics(
      button: true,
      selected: selected,
      child: PressableScale(
        onTap: onTap,
        haptic: PressHaptic.none,
        child: AnimatedContainer(
          duration: AppMotion.short,
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            color: selected ? c.withValues(alpha: 0.10) : Colors.transparent,
            border: Border.all(
              color: selected ? c.withValues(alpha: 0.6) : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: AppMotion.short,
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? c : hud.textMuted.withValues(alpha: 0.6),
                    width: 1.5,
                  ),
                  color: selected ? c : Colors.transparent,
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: c.withValues(alpha: 0.7 * hud.glowStrength),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mode == AssistantMode.draft
                          ? '${mode.label} (default)'
                          : mode.label,
                      style: t.titleSmall,
                    ),
                    Text(
                      mode.description,
                      style: t.bodySmall?.copyWith(color: hud.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppsSection extends ConsumerWidget {
  const _AppsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final apps = ref.watch(messagingAppsProvider).value ?? const [];
    final byPkg = {for (final a in apps) a.packageName: a};
    final installed = ref.watch(launchableAppsProvider).value;
    final installedPkgs = installed?.map((a) => a.packageName).toSet();

    final entries = <(String, String, MessagingAppSetting?)>[
      for (final k in knownMessagingApps)
        (k.packageName, k.label, byPkg[k.packageName]),
      for (final a in apps)
        if (knownApp(a.packageName) == null) (a.packageName, a.appLabel, a),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...spaced([
          for (final (pkg, label, row) in entries)
            _AppTile(
              packageName: pkg,
              label: label,
              row: row,
              installed: installedPkgs?.contains(pkg),
            ),
        ]),
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton.icon(
          onPressed: () => _addApp(context, ref, installed ?? const []),
          icon: const Icon(Icons.add),
          label: const Text('Add another app'),
        ),
      ],
    );
  }

  Future<void> _addApp(
    BuildContext context,
    WidgetRef ref,
    List<LaunchableApp> installed,
  ) async {
    final picked = await showModalBottomSheet<LaunchableApp>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.7,
          child: installed.isEmpty
              ? const EmptyState(
                  icon: Icons.apps,
                  title: 'No apps found',
                  message: 'App list is only available on Android.',
                )
              : ListView(
                  children: [
                    for (final a in installed)
                      ListTile(
                        title: Text(a.label),
                        subtitle: Text(a.packageName),
                        onTap: () => Navigator.pop(ctx, a),
                      ),
                  ],
                ),
        ),
      ),
    );
    if (picked == null) return;
    await ref
        .read(assistantControllerProvider)
        .updateApp(picked.packageName, appLabel: picked.label);
  }
}

class _AppTile extends ConsumerWidget {
  const _AppTile({
    required this.packageName,
    required this.label,
    required this.row,
    required this.installed,
  });
  final String packageName;
  final String label;
  final MessagingAppSetting? row;
  final bool? installed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final enabled = row?.enabled ?? false;
    final mode = AssistantMode.fromKey(row?.mode);
    final blocked = isAutoSendBlockedInCode(packageName);
    final policy = autoSendPolicyFor(packageName);
    final note = knownApp(packageName)?.note ?? unverifiedNote;
    final ctl = ref.read(assistantControllerProvider);

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InitialsAvatar(
                name: label,
                seed: packageName,
                size: 36,
                halo: enabled ? AppColors.success : null,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: t.titleSmall),
                    Text(
                      installed == false
                          ? '$packageName · not installed'
                          : packageName,
                      style: t.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              HudToggle(
                key: Key('app_enabled_$packageName'),
                semanticLabel: 'Read $label',
                value: enabled,
                onChanged: (v) =>
                    ctl.updateApp(packageName, appLabel: label, enabled: v),
              ),
            ],
          ),
          if (policy == AutoSendPolicy.tosBlocked)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: NoticeBanner(
                message: 'Auto-reply blocked. $note',
                icon: Icons.gavel,
                color: AppColors.warning,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                blocked ? 'Auto-reply blocked. $note' : note,
                style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          if (enabled) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                const Expanded(child: Text('Mode')),
                DropdownButton<AssistantMode>(
                  value: mode,
                  items: [
                    for (final m in AssistantMode.values)
                      DropdownMenuItem(
                        value: m,
                        enabled:
                            !(blocked && m == AssistantMode.restrictedAuto),
                        child: Text(
                          blocked && m == AssistantMode.restrictedAuto
                              ? '${m.label} (blocked)'
                              : m.label,
                        ),
                      ),
                  ],
                  onChanged: (m) {
                    if (m == null) return;
                    if (blocked && m == AssistantMode.restrictedAuto) return;
                    ctl.updateApp(packageName, appLabel: label, mode: m);
                  },
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow AI'),
              subtitle: const Text(
                'Message text from this app may be sent to the AI backend '
                '(also needs AI consent).',
              ),
              value: row?.allowAi ?? false,
              onChanged: (v) =>
                  ctl.updateApp(packageName, appLabel: label, allowAi: v),
            ),
            Row(
              children: [
                const Expanded(child: Text('Keep captured messages')),
                DropdownButton<int>(
                  value: const [1, 3, 7, 14, 30].contains(row?.retentionDays)
                      ? row!.retentionDays
                      : 7,
                  items: [
                    for (final d in const [1, 3, 7, 14, 30])
                      DropdownMenuItem(
                        value: d,
                        child: Text(d == 1 ? '1 day' : '$d days'),
                      ),
                  ],
                  onChanged: (d) => d == null
                      ? null
                      : ctl.updateApp(
                          packageName,
                          appLabel: label,
                          retentionDays: d,
                        ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ConversationsSection extends ConsumerWidget {
  const _ConversationsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(contactRulesProvider).value ?? const [];
    final apps = ref.watch(messagingAppsProvider).value ?? const [];
    final labels = {for (final a in apps) a.packageName: a.appLabel};
    if (rules.isEmpty) {
      return const AppCard(
        child: Text(
          'Conversations appear here after their first captured message. '
          'Group chats are ignored until you approve them.',
        ),
      );
    }
    return Column(
      children: spaced([
        for (final r in rules)
          _ContactTile(rule: r, appLabel: appLabelFor(r.packageName, labels)),
      ], gap: AppSpacing.sm),
    );
  }
}

class _ContactTile extends ConsumerWidget {
  const _ContactTile({required this.rule, required this.appLabel});
  final MessagingContactRule rule;
  final String appLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final ctl = ref.read(assistantControllerProvider);
    final tone = ContactTone.parse(rule.toneJson);
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${rule.displayName} · $appLabel',
                  style: t.titleSmall,
                ),
              ),
              if (rule.isGroup)
                const StatusPill('Group', color: AppColors.info),
              const SizedBox(width: AppSpacing.xs),
              StatusPill(
                rule.identityConfidence == 'high' ? 'Identified' : 'Name only',
                color: rule.identityConfidence == 'high'
                    ? AppColors.success
                    : AppColors.warning,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'approved', label: Text('Approved')),
              ButtonSegment(value: 'neutral', label: Text('Neutral')),
              ButtonSegment(value: 'blocked', label: Text('Blocked')),
            ],
            selected: {rule.rule},
            onSelectionChanged: (s) => ctl.updateContact(rule, rule: s.first),
          ),
          Row(
            children: [
              const Expanded(child: Text('Max auto-replies / day')),
              DropdownButton<int>(
                value: rule.maxAutoRepliesPerDay.clamp(0, 5),
                items: [
                  for (var i = 0; i <= 5; i++)
                    DropdownMenuItem(value: i, child: Text('$i')),
                ],
                onChanged: (v) => v == null
                    ? null
                    : ctl.updateContact(rule, maxAutoRepliesPerDay: v),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  tone == null || tone.isEmpty
                      ? 'Tone: your default'
                      : 'Tone: ${[tone.formality, tone.emoji == null ? null : 'emoji ${tone.emoji}', tone.notes].whereType<String>().join(' · ')}',
                  style: t.bodySmall,
                ),
              ),
              TextButton(
                onPressed: () => _editTone(context, ref, tone),
                child: const Text('Tone'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _editTone(
    BuildContext context,
    WidgetRef ref,
    ContactTone? current,
  ) async {
    var formality = current?.formality;
    var emoji = current?.emoji;
    final notes = TextEditingController(text: current?.notes ?? '');
    final result = await showDialog<ContactTone?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Tone for ${rule.displayName}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String?>(
                initialValue: formality,
                decoration: const InputDecoration(labelText: 'Formality'),
                items: const [
                  DropdownMenuItem(value: null, child: Text('Default')),
                  DropdownMenuItem(value: 'casual', child: Text('Casual')),
                  DropdownMenuItem(value: 'neutral', child: Text('Neutral')),
                  DropdownMenuItem(value: 'formal', child: Text('Formal')),
                ],
                onChanged: (v) => setState(() => formality = v),
              ),
              DropdownButtonFormField<String?>(
                initialValue: emoji,
                decoration: const InputDecoration(labelText: 'Emoji'),
                items: const [
                  DropdownMenuItem(value: null, child: Text('Default')),
                  DropdownMenuItem(value: 'none', child: Text('None')),
                  DropdownMenuItem(value: 'some', child: Text('Some')),
                  DropdownMenuItem(value: 'lots', child: Text('Lots')),
                ],
                onChanged: (v) => setState(() => emoji = v),
              ),
              TextField(
                controller: notes,
                decoration: const InputDecoration(
                  labelText: 'Notes (e.g. "reply in Hindi")',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                ctx,
                ContactTone(
                  formality: formality,
                  emoji: emoji,
                  notes: notes.text,
                ),
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    notes.dispose();
    if (result == null) return;
    await ref
        .read(assistantControllerProvider)
        .updateContact(
          rule,
          toneJson: result.isEmpty ? null : result.toJsonString(),
          clearTone: result.isEmpty,
        );
  }
}

class _LimitsCard extends ConsumerWidget {
  const _LimitsCard({required this.limits});
  final PolicyLimits limits;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctl = ref.read(assistantControllerProvider);
    PolicyLimits copy({
      Set<String>? cats,
      int? conv,
      int? daily,
      double? threshold,
      int? qs,
      int? qe,
      int? maxLen,
    }) => PolicyLimits(
      permittedCategories: cats ?? limits.permittedCategories,
      perConversationDailyCap: conv ?? limits.perConversationDailyCap,
      dailyCap: daily ?? limits.dailyCap,
      confidenceThreshold: threshold ?? limits.confidenceThreshold,
      quietStartMinutes: qs ?? limits.quietStartMinutes,
      quietEndMinutes: qe ?? limits.quietEndMinutes,
      maxLength: maxLen ?? limits.maxLength,
    );

    Future<void> pickTime(bool start) async {
      final m = start ? limits.quietStartMinutes : limits.quietEndMinutes;
      final t = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60),
      );
      if (t == null) return;
      final v = t.hour * 60 + t.minute;
      await ctl.setLimits(start ? copy(qs: v) : copy(qe: v));
    }

    Widget intRow(
      String label,
      int value,
      List<int> options,
      void Function(int) set,
    ) => Row(
      children: [
        Expanded(child: Text(label)),
        DropdownButton<int>(
          value: options.contains(value) ? value : options.first,
          items: [
            for (final o in options)
              DropdownMenuItem(value: o, child: Text('$o')),
          ],
          onChanged: (v) => v == null ? null : set(v),
        ),
      ],
    );

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Permitted reply types'),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final c in ReplyCategory.all)
                FilterChip(
                  label: Text(ReplyCategory.label(c)),
                  selected: limits.permittedCategories.contains(c),
                  onSelected: (on) {
                    final next = {...limits.permittedCategories};
                    on ? next.add(c) : next.remove(c);
                    ctl.setLimits(copy(cats: next));
                  },
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          intRow(
            'Max per conversation / day',
            limits.perConversationDailyCap,
            const [0, 1, 2, 3, 5],
            (v) => ctl.setLimits(copy(conv: v)),
          ),
          intRow('Max auto-replies / day', limits.dailyCap, const [
            0,
            3,
            5,
            10,
            20,
          ], (v) => ctl.setLimits(copy(daily: v))),
          intRow('Max reply length (chars)', limits.maxLength, const [
            80,
            120,
            160,
            240,
            320,
          ], (v) => ctl.setLimits(copy(maxLen: v))),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Minimum AI confidence: '
            '${(limits.confidenceThreshold * 100).round()}%',
          ),
          Slider(
            value: limits.confidenceThreshold.clamp(0.5, 0.99),
            min: 0.5,
            max: 0.99,
            divisions: 49,
            label: '${(limits.confidenceThreshold * 100).round()}%',
            onChanged: (_) {},
            onChangeEnd: (v) => ctl.setLimits(copy(threshold: v)),
          ),
          Row(
            children: [
              const Expanded(child: Text('Quiet hours (no auto-replies)')),
              TextButton(
                onPressed: () => pickTime(true),
                child: Text(formatMinutes(limits.quietStartMinutes)),
              ),
              const Text('–'),
              TextButton(
                onPressed: () => pickTime(false),
                child: Text(formatMinutes(limits.quietEndMinutes)),
              ),
            ],
          ),
          const Text(
            'Restricted auto-reply also always requires: an app that allows '
            'it (never WhatsApp), an approved contact identified reliably, no '
            'sensitive content, not a group, and a reply action.',
          ),
        ],
      ),
    );
  }
}

class _ToneCard extends ConsumerStatefulWidget {
  const _ToneCard({required this.tone});
  final ToneProfile tone;

  @override
  ConsumerState<_ToneCard> createState() => _ToneCardState();
}

class _ToneCardState extends ConsumerState<_ToneCard> {
  late final _languages = TextEditingController(
    text: widget.tone.languages.join(', '),
  );
  late final _greetings = TextEditingController(
    text: widget.tone.greetings.join(', '),
  );
  late final _signOffs = TextEditingController(
    text: widget.tone.signOffs.join(', '),
  );
  late final _avoid = TextEditingController(
    text: widget.tone.avoidPhrases.join(', '),
  );
  late final _examples = TextEditingController(
    text: widget.tone.examples.join('\n'),
  );

  @override
  void dispose() {
    for (final c in [_languages, _greetings, _signOffs, _avoid, _examples]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> _split(String s, Pattern p) =>
      s.split(p).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  Future<void> _save(ToneProfile base) async {
    await ref
        .read(assistantControllerProvider)
        .setTone(
          base.copyWith(
            languages: _split(_languages.text, ','),
            greetings: _split(_greetings.text, ','),
            signOffs: _split(_signOffs.text, ','),
            avoidPhrases: _split(_avoid.text, ','),
            examples: _split(_examples.text, '\n'),
          ),
        );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Tone saved')));
    }
  }

  Widget _segments(
    String label,
    String value,
    List<String> options,
    void Function(String) onPick,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        const SizedBox(height: AppSpacing.xs),
        SegmentedButton<String>(
          segments: [
            for (final o in options)
              ButtonSegment(
                value: o,
                label: Text(o[0].toUpperCase() + o.substring(1)),
              ),
          ],
          selected: {options.contains(value) ? value : options[1]},
          onSelectionChanged: (s) => onPick(s.first),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tone = widget.tone;
    final ctl = ref.read(assistantControllerProvider);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _segments('Formality', tone.formality, const [
            'casual',
            'neutral',
            'formal',
          ], (v) => ctl.setTone(tone.copyWith(formality: v))),
          _segments('Length', tone.brevity, const [
            'short',
            'medium',
            'detailed',
          ], (v) => ctl.setTone(tone.copyWith(brevity: v))),
          _segments('Emoji', tone.emoji, const [
            'none',
            'some',
            'lots',
          ], (v) => ctl.setTone(tone.copyWith(emoji: v))),
          TextField(
            controller: _languages,
            decoration: const InputDecoration(
              labelText: 'Languages (comma-separated)',
            ),
          ),
          TextField(
            controller: _greetings,
            decoration: const InputDecoration(labelText: 'Greetings you use'),
          ),
          TextField(
            controller: _signOffs,
            decoration: const InputDecoration(labelText: 'Sign-offs you use'),
          ),
          TextField(
            controller: _avoid,
            decoration: const InputDecoration(labelText: 'Phrases to avoid'),
          ),
          TextField(
            controller: _examples,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Example messages in your voice (one per line)',
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: () => _save(tone),
              child: const Text('Save tone'),
            ),
          ),
        ],
      ),
    );
  }
}

class _AiCard extends ConsumerWidget {
  const _AiCard({required this.settings});
  final AssistantSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drafter = ref.watch(replyDrafterProvider);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!drafter.isConfigured)
            const Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.sm),
              child: NoticeBanner(
                message:
                    '$aiUnavailableMessage. You can always write drafts '
                    'yourself.',
                color: AppColors.warning,
                icon: Icons.cloud_off,
              ),
            ),
          const Text(
            'What is sent to AI: only the captured notification text of the '
            'one conversation you are drafting for (within retention), your '
            'tone profile and that contact\'s tone notes. Never other chats, '
            'health data, or messages flagged as codes, credentials or '
            'emergencies. AI never decides what gets sent — the rules above '
            'do, in code.',
          ),
          SwitchListTile(
            key: const Key('ai_consent_switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow AI drafting & summaries'),
            subtitle: const Text(
              'Also requires "Allow AI" on each app. Off by default.',
            ),
            value: settings.aiConsent,
            onChanged: (v) =>
                ref.read(assistantControllerProvider).setAiConsent(v),
          ),
        ],
      ),
    );
  }
}

class _BriefingCard extends ConsumerWidget {
  const _BriefingCard({required this.settings});
  final AssistantSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctl = ref.read(assistantControllerProvider);
    final b = settings.briefing;
    Future<void> pick(bool morning) async {
      final m = morning ? b.morningMinutes : b.eveningMinutes;
      final t = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60),
      );
      if (t == null) return;
      final v = t.hour * 60 + t.minute;
      await ctl.setBriefing(
        morning ? b.copyWith(morningMinutes: v) : b.copyWith(eveningMinutes: v),
      );
    }

    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Morning briefing'),
            subtitle: Text('At ${formatMinutes(b.morningMinutes)}'),
            value: b.morningEnabled,
            onChanged: (v) => ctl.setBriefing(b.copyWith(morningEnabled: v)),
            secondary: IconButton(
              icon: const Icon(Icons.schedule),
              onPressed: () => pick(true),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Evening review'),
            subtitle: Text('At ${formatMinutes(b.eveningMinutes)}'),
            value: b.eveningEnabled,
            onChanged: (v) => ctl.setBriefing(b.copyWith(eveningEnabled: v)),
            secondary: IconButton(
              icon: const Icon(Icons.schedule),
              onPressed: () => pick(false),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Notify me when a reply needs approval'),
            subtitle: const Text('Content-free notification'),
            value: settings.approvalNotifications,
            onChanged: ctl.setApprovalNotifications,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Assistant mode (foreground service)'),
            subtitle: const Text(
              'Keeps the app alive on an always-on phone with a persistent '
              'notification. ColorOS may still stop it unless battery '
              'optimisation is off.',
            ),
            value: settings.serviceEnabled,
            onChanged: settings.killSwitch
                ? null
                : (v) async {
                    await ctl.setServiceEnabled(v);
                    ref.invalidate(assistantDeviceStatusProvider);
                  },
          ),
          const Text(
            'Briefings are posted only while the app (or Assistant mode) is '
            'running at that time.',
          ),
        ],
      ),
    );
  }
}

class _DataCard extends ConsumerWidget {
  const _DataCard({required this.settings});
  final AssistantSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Captured messages are kept on this phone only and deleted '
            'automatically after each app\'s retention period. The automation '
            'log never contains message text.',
          ),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            key: const Key('delete_all_captured'),
            style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
            icon: const Icon(Icons.delete_forever),
            label: const Text('Delete all captured messages'),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Delete all captured messages?'),
                  content: const Text(
                    'Removes every captured message and the text of every '
                    'draft. Settings and the content-free log are kept.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              if (ok != true) return;
              await ref.read(assistantControllerProvider).deleteAllCaptured();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Captured messages deleted')),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
