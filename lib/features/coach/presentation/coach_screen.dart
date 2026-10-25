import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../agent/coach_controller.dart';
import '../data/ai_backend.dart';
import '../data/coach_repository.dart';
import 'widgets/chat_widgets.dart';

const coachSuggestedPrompts = [
  'How much protein do I have left today?',
  'What can I eat to hit my protein?',
  'How many steps left?',
  'Days until my competition?',
  'Plan a 45-min workout slot today',
  'How did my last workout compare?',
];

class CoachScreen extends ConsumerStatefulWidget {
  const CoachScreen({super.key, this.initialPrompt});

  /// Prefills the composer (from `/coach?prompt=...`). Never auto-sent.
  final String? initialPrompt;

  @override
  ConsumerState<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends ConsumerState<CoachScreen> {
  late final TextEditingController _input;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: _clean(widget.initialPrompt));
  }

  @override
  void didUpdateWidget(CoachScreen old) {
    super.didUpdateWidget(old);
    final p = _clean(widget.initialPrompt);
    if (widget.initialPrompt != old.initialPrompt && p.isNotEmpty) {
      _input.text = p;
    }
  }

  static String _clean(String? p) {
    final s = (p ?? '').trim();
    return s.length > 1000 ? s.substring(0, 1000) : s;
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send([String? text]) async {
    final value = (text ?? _input.text).trim();
    if (value.isEmpty) return;
    _input.clear();
    FocusScope.of(context).unfocus();
    await ref.read(coachControllerProvider.notifier).send(value);
  }

  void _showConversations() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => const _ConversationsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(coachControllerProvider);
    final backendState = ref.watch(aiBackendStateProvider);
    final controller = ref.read(coachControllerProvider.notifier);
    final ready = backendState == AiBackendState.ready;
    final scheme = Theme.of(context).colorScheme;

    final items = <Widget>[
      if (state.entries.isEmpty)
        _Welcome(onPrompt: (p) => ready ? _send(p) : _input.text = p),
      for (final e in state.entries)
        switch (e) {
          UserTextEntry() => MessageBubble.user(e.text),
          AssistantTextEntry() => MessageBubble.assistant(
            e.text,
            sources: e.sources,
          ),
          ToolChipEntry() => ToolActivityChip(e),
        },
      if (state.busy)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Row(
            children: [
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                state.statusText ?? 'Working…',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      if (state.pending != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: PendingActionCard(
            pending: state.pending!,
            onApprove: (edited) => controller.approve(editedArgs: edited),
            onReject: controller.reject,
          ),
        ),
      if (state.error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: NoticeBanner(
            message: state.error!.message,
            icon: Icons.error_outline,
            color: AppColors.danger,
            actionLabel: state.canRetry
                ? 'Retry'
                : state.error!.code == 'awaiting_credentials' ||
                      state.error!.code == 'unauthorized' ||
                      state.error!.code == 'budget_exceeded'
                ? 'Settings'
                : null,
            onAction: state.canRetry
                ? controller.retry
                : () => context.push(AppPaths.aiSettings),
          ),
        ),
      if (state.notice != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: NoticeBanner(message: state.notice!),
        ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Coach'),
        actions: [
          IconButton(
            tooltip: 'Conversations',
            icon: const Icon(Icons.forum_outlined),
            onPressed: _showConversations,
          ),
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: state.busy ? null : controller.newConversation,
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) => context.push(v),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: AppPaths.aiMemory,
                child: Text('Coach memory'),
              ),
              PopupMenuItem(
                value: AppPaths.aiHistory,
                child: Text('AI activity log'),
              ),
              PopupMenuItem(
                value: AppPaths.aiSettings,
                child: Text('AI settings'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (!ready)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.sm,
                  AppSpacing.gutter,
                  0,
                ),
                child: NoticeBanner(
                  icon: Icons.cloud_off_outlined,
                  color: AppColors.warning,
                  message: backendState == AiBackendState.unconfigured
                      ? 'AI backend not configured. The coach needs your '
                            'Supabase project and a provider key — no answers '
                            'are generated until then.'
                      : 'Sign in to your AI backend to start coaching.',
                  actionLabel: 'Set up',
                  onAction: () => context.push(AppPaths.aiSettings),
                ),
              ),
            Expanded(
              child: ListView(
                controller: _scroll,
                reverse: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.gutter,
                  vertical: AppSpacing.md,
                ),
                children: items.reversed.toList(),
              ),
            ),
            _Composer(
              controller: _input,
              enabled: ready && state.pending == null,
              busy: state.busy,
              onSend: _send,
              onStop: controller.cancel,
            ),
          ],
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onPrompt});
  final void Function(String) onPrompt;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(
              gradient: AppGradients.brand,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.auto_awesome, color: Colors.white),
          ),
          const SizedBox(height: AppSpacing.md),
          Text('Your coach, grounded in your data', style: t.titleLarge),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Answers cite your logs and sources. Nothing is changed without '
            'your approval.',
            style: t.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final p in coachSuggestedPrompts)
                ActionChip(label: Text(p), onPressed: () => onPrompt(p)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.busy,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool busy;
  final Future<void> Function([String?]) onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.sm,
            AppSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: 4000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'Ask your coach…',
                    counterText: '',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(
                        Radius.circular(AppRadii.lg),
                      ),
                    ),
                    isDense: true,
                  ),
                  onSubmitted: enabled && !busy ? (_) => onSend() : null,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              busy
                  ? IconButton.filledTonal(
                      tooltip: 'Stop',
                      onPressed: onStop,
                      icon: const Icon(Icons.stop),
                    )
                  : IconButton.filled(
                      tooltip: 'Send',
                      onPressed: enabled ? () => onSend() : null,
                      icon: const Icon(Icons.arrow_upward),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConversationsSheet extends ConsumerWidget {
  const _ConversationsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final convs = ref.watch(conversationsProvider);
    final controller = ref.read(coachControllerProvider.notifier);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: convs.when(
          loading: () => const LoadingState(),
          error: (e, _) => const ErrorState(message: 'Could not load chats.'),
          data: (list) => ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New chat'),
                onTap: () {
                  controller.newConversation();
                  Navigator.pop(context);
                },
              ),
              if (list.isEmpty)
                const EmptyState(
                  icon: Icons.forum_outlined,
                  title: 'No conversations yet',
                  compact: true,
                ),
              for (final c in list)
                ListTile(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: Text(
                    c.title ?? 'Conversation',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(Fmt.ago(c.updatedAt, DateTime.now())),
                  trailing: IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await ref
                          .read(coachRepositoryProvider)
                          .deleteConversation(c.id);
                      if (ref.read(coachControllerProvider).conversationId ==
                          c.id) {
                        controller.newConversation();
                      }
                    },
                  ),
                  onTap: () {
                    controller.openConversation(c.id);
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
