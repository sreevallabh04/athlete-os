import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/util/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../data/db/database.dart';
import '../../application/providers.dart';
import '../../domain/assistant_models.dart';
import '../../domain/sensitivity_classifier.dart';
import 'assistant_widgets.dart';

/// One reply waiting for the user: captured text, editable draft, risk flags
/// and Send / Reject / Copy & open. Sending only ever happens from the Send
/// button of this specific draft.
class DraftCard extends ConsumerStatefulWidget {
  const DraftCard({
    super.key,
    required this.draft,
    required this.appLabel,
    required this.messages,
  });

  final ReplyDraft draft;
  final String appLabel;

  /// Captured messages of this conversation, oldest first.
  final List<CapturedNotification> messages;

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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _save() async {
    if (!_dirty) return;
    await ref.read(replyServiceProvider).editDraft(widget.draft.id, _text.text);
    _dirty = false;
  }

  Future<void> _send() async {
    final flags = SensitivityResult.parseCsv(widget.draft.riskFlags);
    final content = flags.where((f) => f.isContent).toList();
    if (content.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.shield_outlined),
          title: const Text('Sensitive conversation'),
          content: Text(
            'This conversation looks sensitive '
            '(${content.map((f) => f.label).join(', ')}). '
            'Check the reply carefully. Send it anyway?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Send'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      await _save();
      final r = await ref
          .read(replyServiceProvider)
          .approveAndSend(widget.draft.id);
      _snack(r.message);
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
    _snack('Draft rejected.');
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
    final scheme = Theme.of(context).colorScheme;
    final now = ref.watch(clockProvider).now();
    final flags = SensitivityResult.parseCsv(d.riskFlags);
    final source = _source;
    final canReply = source?.hasReplyAction ?? false;
    final killed =
        ref.watch(assistantSettingsProvider).value?.killSwitch ?? false;
    final title =
        source?.conversationTitle ?? source?.sender ?? d.conversationKey ?? '';

    return AppCard(
      accent: d.risk == 'high' ? AppColors.warning : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
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
          const SizedBox(height: AppSpacing.xs),
          for (final m in widget.messages)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '${m.isGroup && m.sender != null ? '${m.sender}: ' : ''}'
                '${m.body}',
                style: t.bodyMedium,
              ),
            ),
          if (widget.messages.isEmpty)
            Text(
              'Original message expired (retention).',
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          if (source != null)
            Text(
              Fmt.ago(source.postedAt, now),
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          const SizedBox(height: AppSpacing.sm),
          FlagChips(flags),
          const SizedBox(height: AppSpacing.sm),
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
                style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                key: Key('send_${d.id}'),
                onPressed: _busy || killed || !canReply ? null : _send,
                icon: const Icon(Icons.send, size: 18),
                label: const Text('Send'),
              ),
              OutlinedButton(
                onPressed: _busy || killed ? null : _copyAndOpen,
                child: const Text('Copy & open'),
              ),
              TextButton(
                onPressed: _busy || killed ? null : _draftWithAi,
                child: const Text('Draft with AI'),
              ),
              TextButton(
                onPressed: _busy ? null : _reject,
                child: const Text('Reject'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
