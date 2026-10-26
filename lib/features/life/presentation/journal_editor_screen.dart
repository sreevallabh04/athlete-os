import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../application/mood_journal_providers.dart';
import '../data/journal_repository.dart';
import '../domain/crisis_detector.dart';
import '../domain/journal_text.dart';
import 'journal_screen.dart' show AiJournalConsentCard;
import 'widgets/life_widgets.dart';

enum _SaveState { idle, pending, saving, saved, failed }

/// Journal editor with autosave and a distraction-free focus mode. Entries
/// stay on this device.
class JournalEditorScreen extends ConsumerStatefulWidget {
  const JournalEditorScreen({super.key, this.entryId, this.initialPrompt});
  final String? entryId;

  /// Pre-selected reflection prompt for a new entry.
  final String? initialPrompt;

  @override
  ConsumerState<JournalEditorScreen> createState() =>
      _JournalEditorScreenState();
}

class _JournalEditorScreenState extends ConsumerState<JournalEditorScreen> {
  final _body = TextEditingController();
  final _gratitude = TextEditingController();
  late final JournalRepository _repo;
  String? _id;
  late String _localDate;
  String? _prompt;
  int _promptSeed = 0;
  bool _loading = true;
  bool _focus = false;
  Timer? _debounce;
  _SaveState _state = _SaveState.idle;
  Future<void>? _inFlight;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(journalRepositoryProvider);
    final now = ref.read(clockProvider).now();
    _localDate = LocalDates.key(now);
    _promptSeed = now.difference(DateTime(2024)).inDays;
    _id = widget.entryId;
    if (widget.entryId == null) {
      _prompt = widget.initialPrompt;
      if (_prompt != null) {
        final i = journalPrompts.indexOf(_prompt!);
        if (i >= 0) _promptSeed = i;
      }
    }
    _load();
  }

  Future<void> _load() async {
    if (_id != null) {
      final e = await _repo.get(_id!);
      if (e != null) {
        _body.text = e.body;
        _gratitude.text = e.gratitude ?? '';
        _prompt = e.prompt;
        _localDate = e.localDate;
        _state = _SaveState.saved;
      }
    }
    _body.addListener(_changed);
    _gratitude.addListener(_changed);
    if (mounted) setState(() => _loading = false);
  }

  bool get _isEmpty =>
      _body.text.trim().isEmpty && _gratitude.text.trim().isEmpty;

  void _changed() {
    _debounce?.cancel();
    if (mounted) setState(() => _state = _SaveState.pending);
    _debounce = Timer(const Duration(milliseconds: 800), _save);
  }

  Future<void> _save() async {
    _debounce?.cancel();
    if (_isEmpty && _id == null) return;
    await _inFlight;
    final run = () async {
      if (mounted) setState(() => _state = _SaveState.saving);
      try {
        _id = await _repo.save(
          id: _id,
          localDate: _localDate,
          body: _body.text,
          gratitude: _gratitude.text,
          prompt: _prompt,
        );
        if (mounted) setState(() => _state = _SaveState.saved);
      } catch (_) {
        if (mounted) setState(() => _state = _SaveState.failed);
      }
    }();
    _inFlight = run;
    await run;
  }

  @override
  void dispose() {
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
      // Flush the last edits; the repository outlives this widget.
      if (!(_isEmpty && _id == null)) {
        unawaited(
          _repo.save(
            id: _id,
            localDate: _localDate,
            body: _body.text,
            gratitude: _gratitude.text,
            prompt: _prompt,
          ),
        );
      }
    }
    _body.dispose();
    _gratitude.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    final ok = await confirmHud(
      context,
      title: 'Delete this entry?',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    _debounce?.cancel();
    await _inFlight;
    if (_id != null) await _repo.softDelete(_id!);
    _id = null;
    _body.removeListener(_changed);
    _gratitude.removeListener(_changed);
    _body.clear();
    _gratitude.clear();
    if (mounted) Navigator.of(context).pop();
  }

  void _setPrompt(String? p) {
    Haptics.selection();
    setState(() => _prompt = p);
    _changed();
  }

  void _toggleFocus() {
    Haptics.selection();
    setState(() => _focus = !_focus);
  }

  Future<void> _reflect() async {
    await _save();
    if (!mounted) return;
    final date = DateFormat('EEEE d MMMM').format(LocalDates.parse(_localDate));
    final prompt =
        'Please reflect on my journal entry from $date. Gently point out '
        'any themes you notice and suggest one small thing I could try.';
    context.go(
      Uri(path: AppPaths.coach, queryParameters: {'prompt': prompt}).toString(),
    );
  }

  String get _statusText => switch (_state) {
    _SaveState.idle => 'Draft',
    _SaveState.pending => 'Editing…',
    _SaveState.saving => 'Saving…',
    _SaveState.saved => 'Saved on this device',
    _SaveState.failed => 'Couldn\'t save — keep this screen open and retry',
  };

  int get _words {
    final s = '${_body.text} ${_gratitude.text}'.trim();
    return s.isEmpty ? 0 : s.split(RegExp(r'\s+')).length;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final reduced = AppMotion.reduced(context);
    final distress = detectsSevereDistress('${_body.text}\n${_gratitude.text}');
    final dur = reduced ? Duration.zero : AppMotion.medium;
    final dotColor = switch (_state) {
      _SaveState.saved => AppColors.success,
      _SaveState.failed => AppColors.danger,
      _SaveState.idle => hud.textMuted,
      _ => AppColors.warning,
    };

    final writing = TextField(
      key: const Key('journal-body'),
      controller: _body,
      autofocus: widget.entryId == null,
      minLines: _focus ? 16 : 10,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textCapitalization: TextCapitalization.sentences,
      cursorColor: hud.accent,
      style: (_focus ? t.bodyLarge?.copyWith(fontSize: 19) : t.bodyLarge)
          ?.copyWith(height: _focus ? 1.75 : 1.6),
      decoration: InputDecoration(
        hintText: 'What\'s on your mind?',
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        hintStyle: t.bodyLarge?.copyWith(
          color: hud.textMuted.withValues(alpha: 0.7),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Focus mode dims the HUD canvas without hiding it.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _focus ? 1 : 0,
                duration: dur,
                child: ColoredBox(
                  color: (hud.isDark ? Colors.black : Colors.white).withValues(
                    alpha: 0.55,
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                // Top chrome.
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
                  child: Row(
                    children: [
                      const BackButton(),
                      Expanded(
                        child: AnimatedOpacity(
                          opacity: _focus ? 0.0 : 1.0,
                          duration: dur,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                DateFormat('EEE d MMM')
                                    .format(LocalDates.parse(_localDate)),
                                style: t.titleMedium,
                              ),
                              const SizedBox(height: 2),
                              Semantics(
                                liveRegion: true,
                                child: Row(
                                  children: [
                                    AnimatedContainer(
                                      duration: AppMotion.short,
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: dotColor,
                                        boxShadow: [
                                          BoxShadow(
                                            color: dotColor.withValues(
                                              alpha: 0.7 * hud.glowStrength,
                                            ),
                                            blurRadius: 6,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        _statusText,
                                        overflow: TextOverflow.ellipsis,
                                        style: hud.mono(
                                          size: 11,
                                          color: _state == _SaveState.failed
                                              ? AppColors.danger
                                              : hud.textMuted,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Text('$_words words', style: hud.mono(size: 11)),
                      IconButton(
                        tooltip: _focus ? 'Exit focus mode' : 'Focus mode',
                        isSelected: _focus,
                        icon: const Icon(Icons.center_focus_weak),
                        selectedIcon: Icon(
                          Icons.center_focus_strong,
                          color: hud.accent,
                        ),
                        onPressed: _toggleFocus,
                      ),
                      if (_id != null && !_focus)
                        IconButton(
                          tooltip: 'Delete entry',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: _delete,
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: _loading
                      ? const Center(child: HudSpinner())
                      : ListView(
                          padding: EdgeInsets.fromLTRB(
                            AppSpacing.gutter,
                            AppSpacing.md,
                            AppSpacing.gutter,
                            MediaQuery.paddingOf(context).bottom +
                                AppSpacing.xxxl,
                          ),
                          children: [
                            AnimatedSize(
                              duration: dur,
                              curve: AppMotion.standard,
                              alignment: Alignment.topCenter,
                              child: _focus
                                  ? const SizedBox(width: double.infinity)
                                  : Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: AppSpacing.md,
                                      ),
                                      child: _PromptBar(
                                        prompt: _prompt,
                                        onUse: () =>
                                            _setPrompt(promptFor(_promptSeed)),
                                        onNext: () => _setPrompt(
                                          promptFor(++_promptSeed),
                                        ),
                                        onRemove: () => _setPrompt(null),
                                      ),
                                    ),
                            ),
                            if (_focus && _prompt != null) ...[
                              Text(
                                _prompt!,
                                style: t.titleMedium?.copyWith(
                                  fontStyle: FontStyle.italic,
                                  color: hud.textMuted,
                                ),
                              ),
                              const SizedBox(height: AppSpacing.lg),
                            ],
                            AnimatedContainer(
                              duration: dur,
                              curve: AppMotion.standard,
                              padding: EdgeInsets.all(
                                _focus ? 0 : AppSpacing.lg,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: AppRadii.card,
                                color: _focus
                                    ? Colors.transparent
                                    : hud.glassFill,
                                border: Border.all(
                                  color: _focus
                                      ? Colors.transparent
                                      : hud.hairline.withValues(alpha: 0.16),
                                ),
                              ),
                              child: writing,
                            ),
                            AnimatedSize(
                              duration: dur,
                              curve: AppMotion.standard,
                              alignment: Alignment.topCenter,
                              child: _focus
                                  ? const SizedBox(width: double.infinity)
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        const SizedBox(height: AppSpacing.md),
                                        TextField(
                                          controller: _gratitude,
                                          minLines: 1,
                                          maxLines: 3,
                                          textCapitalization:
                                              TextCapitalization.sentences,
                                          decoration: const InputDecoration(
                                            labelText:
                                                'Grateful for (optional)',
                                            prefixIcon: Icon(
                                              Icons.volunteer_activism_outlined,
                                            ),
                                          ),
                                        ),
                                        if (distress) ...[
                                          const SizedBox(height: AppSpacing.lg),
                                          const SupportCard(),
                                        ],
                                        const SizedBox(height: AppSpacing.lg),
                                        _AiReflection(
                                          canReflect: !_isEmpty,
                                          onReflect: _reflect,
                                        ),
                                        const SizedBox(height: AppSpacing.md),
                                        Row(
                                          children: [
                                            const PrivacyBadge(),
                                            const SizedBox(
                                              width: AppSpacing.sm,
                                            ),
                                            Expanded(
                                              child: Text(
                                                'Autosaves as you type.',
                                                style: t.bodySmall?.copyWith(
                                                  color: hud.textMuted,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                            ),
                            if (_focus && distress) ...[
                              const SizedBox(height: AppSpacing.lg),
                              const SupportCard(),
                            ],
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PromptBar extends StatelessWidget {
  const _PromptBar({
    required this.prompt,
    required this.onUse,
    required this.onNext,
    required this.onRemove,
  });
  final String? prompt;
  final VoidCallback onUse;
  final VoidCallback onNext;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    if (prompt == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: HudChip(
            label: 'Use a reflection prompt',
            icon: Icons.lightbulb_outline,
            uppercase: false,
            onTap: onUse,
          ),
        ),
      );
    }
    return GlassPanel(
      accent: hud.accent,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.xs,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: AppMotion.medium,
              child: Text(
                prompt!,
                key: ValueKey(prompt),
                style: t.bodyLarge?.copyWith(fontStyle: FontStyle.italic),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Another prompt',
            icon: const Icon(Icons.refresh),
            onPressed: onNext,
          ),
          IconButton(
            tooltip: 'Remove prompt',
            icon: const Icon(Icons.close),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// AI reflection: only offered when the user has opted in (default off).
/// While off, explains that and lets them opt in through the same
/// disclosure as the Journal screen.
class _AiReflection extends ConsumerWidget {
  const _AiReflection({required this.canReflect, required this.onReflect});
  final bool canReflect;
  final VoidCallback onReflect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(aiJournalConsentProvider).value ?? false;
    final hud = context.hud;
    return GlassPanel(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: HudRow(
        leading: GlowIcon(
          Icons.auto_awesome_outlined,
          size: 18,
          color: on ? hud.accent : hud.textMuted,
          glow: on ? 1 : 0,
        ),
        title: 'AI reflection',
        subtitle: on
            ? 'Ask the AI coach to reflect on this entry. Sent only when you '
                  'tap.'
            : 'Off — your words stay on this device. Turn it on to ask the '
                  'coach for a gentle reflection.',
        trailing: on
            ? HudButton.secondary(
                label: 'Reflect',
                compact: true,
                onPressed: canReflect ? onReflect : null,
              )
            : HudButton.ghost(
                label: 'Turn on',
                compact: true,
                onPressed: () => AiJournalConsentCard.set(context, ref, true),
              ),
      ),
    );
  }
}
