import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/util/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../data/db/database.dart';
import '../../application/providers.dart';
import '../../domain/assistant_models.dart';
import '../../domain/priority.dart';
import '../../domain/sensitivity_classifier.dart';
import 'assistant_widgets.dart';

/// User-initiated draft actions shared by the inbox tile, its swipe
/// gestures and the editor sheet. Every send goes through
/// [ReplyService.approveAndSend] for one specific draft — the policy and
/// safety checks live there, untouched.
abstract final class DraftActions {
  static void _snack(BuildContext context, String msg) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Extra confirmation when the conversation looks sensitive.
  static Future<bool> confirmSensitive(
    BuildContext context,
    ReplyDraft d,
  ) async {
    final content = SensitivityResult.parseCsv(d.riskFlags)
        .where((f) => f.isContent)
        .toList();
    if (content.isEmpty) return true;
    final ok = await showHudBottomSheet<bool>(
      context,
      title: 'Sensitive conversation',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FlagChips(content.toSet()),
          const SizedBox(height: AppSpacing.md),
          Text(
            'This conversation looks sensitive '
            '(${content.map((f) => f.label).join(', ')}). '
            'Check the reply carefully. Send it anyway?',
            style: Theme.of(ctx).textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.lg),
          HudButton(
            label: 'Send',
            icon: Icons.send_rounded,
            expand: true,
            onPressed: () => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: AppSpacing.sm),
          HudButton.ghost(
            label: 'Cancel',
            expand: true,
            onPressed: () => Navigator.pop(ctx, false),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// "Send this reply?" — used by the swipe gesture.
  static Future<bool> confirmSend(
    BuildContext context,
    ReplyDraft d, {
    required String title,
    required String appLabel,
  }) async {
    final ok = await showHudBottomSheet<bool>(
      context,
      title: 'Send reply?',
      builder: (ctx) {
        final hud = HudTheme.of(ctx);
        final t = Theme.of(ctx).textTheme;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'TO ${title.toUpperCase()} · ${appLabel.toUpperCase()}',
              style: hud.label(size: 11, color: hud.accentInk),
            ),
            const SizedBox(height: AppSpacing.sm),
            GlassPanel(
              accent: hud.accent,
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text(d.draftText, style: t.bodyLarge),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              "Handed to the app's own reply action. Apps do not confirm "
              'delivery.',
              style: hud.mono(size: 10.5),
            ),
            const SizedBox(height: AppSpacing.lg),
            HudButton(
              label: 'Send',
              icon: Icons.send_rounded,
              expand: true,
              onPressed: () => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: AppSpacing.sm),
            HudButton.ghost(
              label: 'Cancel',
              expand: true,
              onPressed: () => Navigator.pop(ctx, false),
            ),
          ],
        );
      },
    );
    return ok == true;
  }

  /// Approves and hands off [d] (optionally saving an edited text first).
  static Future<void> send(
    BuildContext context,
    WidgetRef ref,
    ReplyDraft d, {
    String? editedText,
  }) async {
    if (!await confirmSensitive(context, d)) return;
    final service = ref.read(replyServiceProvider);
    if (editedText != null && editedText != d.draftText) {
      await service.editDraft(d.id, editedText);
    }
    final r = await service.approveAndSend(d.id);
    Haptics.success();
    if (context.mounted) _snack(context, r.message);
  }

  static Future<void> reject(
    BuildContext context,
    WidgetRef ref,
    ReplyDraft d,
  ) async {
    await ref.read(replyServiceProvider).reject(d.id);
    Haptics.medium();
    if (context.mounted) _snack(context, 'Draft rejected.');
  }
}

/// One reply waiting for the user in the triaged inbox: avatar with a
/// priority halo, the latest message, the draft and a one-tap Send.
///
/// Swipe right → approve & send (after a confirmation sheet); swipe left →
/// dismiss (reject). Tap → full draft editor.
class DraftInboxTile extends ConsumerStatefulWidget {
  const DraftInboxTile({
    super.key,
    required this.draft,
    required this.appLabel,
    required this.messages,
    this.primary = false,
  });

  final ReplyDraft draft;
  final String appLabel;

  /// Captured messages of this conversation, oldest first.
  final List<CapturedNotification> messages;

  /// The top-priority tile gets the one primary Send on screen.
  final bool primary;

  @override
  ConsumerState<DraftInboxTile> createState() => _DraftInboxTileState();
}

class _DraftInboxTileState extends ConsumerState<DraftInboxTile> {
  bool _busy = false;

  CapturedNotification? get _source {
    for (final m in widget.messages) {
      if (m.id == widget.draft.notificationId) return m;
    }
    return widget.messages.isEmpty ? null : widget.messages.last;
  }

  String get _title {
    final s = _source;
    return s?.conversationTitle ??
        s?.sender ??
        widget.draft.conversationKey ??
        'Unknown';
  }

  Future<void> _guard(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openEditor() {
    showHudBottomSheet<void>(
      context,
      title: 'Reply',
      builder: (_) => SingleChildScrollView(
        child: DraftCard(
          draft: widget.draft,
          appLabel: widget.appLabel,
          messages: widget.messages,
          embedded: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final hud = HudTheme.of(context);
    final t = Theme.of(context).textTheme;
    final now = ref.watch(clockProvider).now();
    final killed =
        ref.watch(assistantSettingsProvider).value?.killSwitch ?? false;
    final source = _source;
    final canReply = source?.hasReplyAction ?? false;
    final flags = SensitivityResult.parseCsv(d.riskFlags);
    final priority = source == null
        ? null
        : priorityOf(
            text: source.body,
            flags: flags,
            postedAt: source.postedAt,
            now: now,
          );
    final Color? halo = d.risk == 'high'
        ? AppColors.danger
        : (priority?.isPriority ?? false)
        ? AppColors.warning
        : null;
    final canSend =
        !_busy && !killed && canReply && d.draftText.trim().isNotEmpty;

    final tile = AppCard(
      accent: halo,
      glow: halo != null,
      onTap: _openEditor,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InitialsAvatar(
                name: _title,
                seed: d.packageName,
                halo: halo,
                badge: widget.appLabel,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _title,
                            style: t.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (source != null)
                          Text(
                            Fmt.ago(source.postedAt, now).toUpperCase(),
                            style: hud.mono(size: 10),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        widget.appLabel.toUpperCase(),
                        if (priority != null && priority.isPriority)
                          ...priority.reasons
                              .take(2)
                              .map((r) => r.toUpperCase()),
                      ].join(' · '),
                      style: hud.label(
                        size: 10.5,
                        color: halo ?? hud.textMuted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final m in widget.messages.reversed.take(2).toList().reversed)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${m.isGroup && m.sender != null ? '${m.sender}: ' : ''}'
                '${m.body}',
                style: t.bodyMedium,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (widget.messages.isEmpty)
            Text(
              'Original message expired (retention).',
              style: t.bodySmall?.copyWith(color: hud.textMuted),
            ),
          const SizedBox(height: AppSpacing.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
            decoration: BoxDecoration(
              color: hud.accent.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: Border(
                left: BorderSide(
                  color: hud.accent.withValues(alpha: 0.8),
                  width: 2,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  d.confidence != null
                      ? 'DRAFT · ${(d.confidence! * 100).round()}% CONFIDENT'
                      : 'YOUR REPLY',
                  style: hud.label(size: 10, color: hud.accentInk),
                ),
                const SizedBox(height: 2),
                Text(
                  d.draftText.trim().isEmpty
                      ? 'No draft yet. Tap to write one.'
                      : d.draftText,
                  style: t.bodyMedium?.copyWith(
                    color: d.draftText.trim().isEmpty
                        ? hud.textMuted
                        : hud.text,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (flags.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            FlagChips(flags),
          ],
          if (!canReply)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                'No reply action on this notification. Use Copy & open.',
                style: t.bodySmall?.copyWith(color: hud.textMuted),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              if (!killed) ...[
                Icon(Icons.swipe_rounded, size: 14, color: hud.textMuted),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  killed ? 'STOPPED' : 'SWIPE',
                  overflow: TextOverflow.ellipsis,
                  style: hud.mono(
                    size: 9.5,
                    color: killed ? AppColors.danger : hud.textMuted,
                  ),
                ),
              ),
              HudButton.ghost(
                label: 'Edit',
                compact: true,
                onPressed: _openEditor,
              ),
              const SizedBox(width: AppSpacing.xs),
              HudButton(
                key: Key('send_${d.id}'),
                variant: widget.primary
                    ? HudButtonVariant.primary
                    : HudButtonVariant.secondary,
                label: 'Send',
                icon: Icons.send_rounded,
                compact: true,
                loading: _busy,
                onPressed: canSend
                    ? () => _guard(() => DraftActions.send(context, ref, d))
                    : null,
              ),
            ],
          ),
        ],
      ),
    );

    if (killed) return tile;
    return Dismissible(
      key: ValueKey('swipe-${d.id}'),
      direction: canSend
          ? DismissDirection.horizontal
          : DismissDirection.endToStart,
      dismissThresholds: const {
        DismissDirection.startToEnd: 0.35,
        DismissDirection.endToStart: 0.35,
      },
      background: _SwipeBg(
        color: hud.accent,
        icon: Icons.send_rounded,
        label: 'APPROVE & SEND',
        alignLeft: true,
      ),
      secondaryBackground: const _SwipeBg(
        color: AppColors.danger,
        icon: Icons.close_rounded,
        label: 'DISMISS',
        alignLeft: false,
      ),
      confirmDismiss: (dir) async {
        Haptics.medium();
        if (dir == DismissDirection.startToEnd) {
          final ok = await DraftActions.confirmSend(
            context,
            d,
            title: _title,
            appLabel: widget.appLabel,
          );
          if (ok && context.mounted) {
            unawaited(_guard(() => DraftActions.send(context, ref, d)));
          }
        } else {
          unawaited(DraftActions.reject(context, ref, d));
        }
        // The stream removes the tile; never dismiss locally.
        return false;
      },
      child: tile,
    );
  }
}

class _SwipeBg extends StatelessWidget {
  const _SwipeBg({
    required this.color,
    required this.icon,
    required this.label,
    required this.alignLeft,
  });

  final Color color;
  final IconData icon;
  final String label;
  final bool alignLeft;

  @override
  Widget build(BuildContext context) {
    final hud = HudTheme.of(context);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GlowIcon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(label, style: hud.label(size: 12, color: color)),
      ],
    );
    return Container(
      alignment: alignLeft ? Alignment.centerLeft : Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        gradient: LinearGradient(
          begin: alignLeft ? Alignment.centerLeft : Alignment.centerRight,
          end: alignLeft ? Alignment.centerRight : Alignment.centerLeft,
          colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0.0)],
        ),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: row,
    );
  }
}

/// Full draft editor: captured conversation, risk flags, editable reply and
/// Send / Copy & open / Draft with AI / Reject. Sending only ever happens
/// from the Send button of this specific draft.
class DraftCard extends ConsumerStatefulWidget {
  const DraftCard({
    super.key,
    required this.draft,
    required this.appLabel,
    required this.messages,
    this.embedded = false,
  });

  final ReplyDraft draft;
  final String appLabel;

  /// Captured messages of this conversation, oldest first.
  final List<CapturedNotification> messages;

  /// Inside a sheet: no card chrome; closes the sheet after an action.
  final bool embedded;

  @override
  ConsumerState<DraftCard> createState() => _DraftCardState();
}

class _DraftCardState extends ConsumerState<DraftCard> {
  late final TextEditingController _text;
  bool _dirty = false;
  bool _busy = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.draft.draftText);
  }

  @override
  void didUpdateWidget(DraftCard old) {
    super.didUpdateWidget(old);
    if (!_dirty && widget.draft.draftText != _text.text) {
      _text.text = widget.draft.draftText;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  CapturedNotification? get _source {
    for (final m in widget.messages) {
      if (m.id == widget.draft.notificationId) return m;
    }
    return widget.messages.isEmpty ? null : widget.messages.last;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(msg)));
  }

  void _close() {
    if (widget.embedded && mounted) Navigator.maybePop(context);
  }

  Future<void> _save() async {
    if (!_dirty) return;
    await ref.read(replyServiceProvider).editDraft(widget.draft.id, _text.text);
    _dirty = false;
  }

  Future<void> _send() async {
    if (!await DraftActions.confirmSensitive(context, widget.draft)) return;
    setState(() => _busy = true);
    try {
      await _save();
      final r = await ref
          .read(replyServiceProvider)
          .approveAndSend(widget.draft.id);
      Haptics.success();
      _snack(r.message);
      _close();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyAndOpen() async {
    setState(() => _busy = true);
    try {
      await _save();
      final r = await ref
          .read(replyServiceProvider)
          .copyAndOpen(widget.draft.id);
      _snack(r.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject() async {
    await ref.read(replyServiceProvider).reject(widget.draft.id);
    Haptics.medium();
    _snack('Draft rejected.');
    _close();
  }

  Future<void> _draftWithAi() async {
    setState(() => _busy = true);
    try {
      final r = await ref
          .read(replyServiceProvider)
          .draftWithAi(widget.draft.id);
      if (!mounted) return;
      if (r.available) {
        _dirty = false;
        setState(() => _note = null);
      } else {
        setState(() => _note = r.needsHumanReason);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final t = Theme.of(context).textTheme;
    final hud = HudTheme.of(context);
    final now = ref.watch(clockProvider).now();
    final flags = SensitivityResult.parseCsv(d.riskFlags);
    final source = _source;
    final canReply = source?.hasReplyAction ?? false;
    final killed =
        ref.watch(assistantSettingsProvider).value?.killSwitch ?? false;
    final title =
        source?.conversationTitle ?? source?.sender ?? d.conversationKey ?? '';

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            InitialsAvatar(name: title, seed: d.packageName, size: 34),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text('$title · ${widget.appLabel}', style: t.titleSmall),
            ),
            StatusPill(
              DraftStatus.label(d.status),
              color: d.status == DraftStatus.pendingApproval
                  ? AppColors.warning
                  : AppColors.info,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        for (final m in widget.messages)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.75,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: hud.text.withValues(alpha: 0.06),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(14),
                    topRight: Radius.circular(14),
                    bottomRight: Radius.circular(14),
                    bottomLeft: Radius.circular(4),
                  ),
                ),
                child: Text(
                  '${m.isGroup && m.sender != null ? '${m.sender}: ' : ''}'
                  '${m.body}',
                  style: t.bodyMedium,
                ),
              ),
            ),
          ),
        if (widget.messages.isEmpty)
          Text(
            'Original message expired (retention).',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
        if (source != null)
          Text(
            Fmt.ago(source.postedAt, now).toUpperCase(),
            style: hud.mono(size: 10),
          ),
        const SizedBox(height: AppSpacing.sm),
        FlagChips(flags),
        const SizedBox(height: AppSpacing.md),
        TextField(
          key: Key('draft_text_${d.id}'),
          controller: _text,
          minLines: 2,
          maxLines: 6,
          enabled: !killed,
          onChanged: (_) => _dirty = true,
          decoration: InputDecoration(
            labelText: 'Your reply',
            hintText: d.draftText.isEmpty
                ? 'Write a reply (AI drafting is optional)'
                : null,
            helperText: d.confidence != null
                ? 'AI draft · ${d.category ?? 'other'} · confidence '
                      '${(d.confidence! * 100).round()}% — edit freely'
                : null,
          ),
        ),
        if (_note != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              _note!,
              style: t.bodySmall?.copyWith(color: AppColors.warning),
            ),
          ),
        if (!canReply)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              '${widget.appLabel} did not offer a reply action for this '
              'notification — use Copy & open.',
              style: t.bodySmall?.copyWith(color: hud.textMuted),
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: HudButton(
                key: Key('editor_send_${d.id}'),
                label: 'Send',
                icon: Icons.send_rounded,
                expand: true,
                loading: _busy,
                onPressed: _busy || killed || !canReply ? null : _send,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            HudButton.secondary(
              label: 'Copy & open',
              onPressed: _busy || killed ? null : _copyAndOpen,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            HudButton.ghost(
              label: 'Draft with AI',
              icon: Icons.auto_awesome_rounded,
              compact: true,
              onPressed: _busy || killed ? null : _draftWithAi,
            ),
            const Spacer(),
            HudButton.ghost(
              label: 'Reject',
              compact: true,
              onPressed: _busy ? null : _reject,
            ),
          ],
        ),
      ],
    );
    if (widget.embedded) return body;
    return AppCard(
      accent: d.risk == 'high' ? AppColors.warning : null,
      child: body,
    );
  }
}
