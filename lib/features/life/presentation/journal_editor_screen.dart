import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/widgets/widgets.dart';
import '../data/journal_repository.dart';
import '../domain/crisis_detector.dart';
import '../domain/journal_text.dart';
import 'widgets/life_widgets.dart';

enum _SaveState { idle, pending, saving, saved, failed }

/// Journal editor with autosave. Entries stay on this device.
class JournalEditorScreen extends ConsumerStatefulWidget {
  const JournalEditorScreen({super.key, this.entryId});
  final String? entryId;

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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this entry?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
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
    setState(() => _prompt = p);
    _changed();
  }

  String get _statusText => switch (_state) {
    _SaveState.idle => 'Draft',
    _SaveState.pending => 'Editing…',
    _SaveState.saving => 'Saving…',
    _SaveState.saved => 'Saved on this device',
    _SaveState.failed => 'Couldn\'t save — keep this screen open and retry',
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final distress = detectsSevereDistress('${_body.text}\n${_gratitude.text}');
    return Scaffold(
      appBar: AppBar(
        title: Text(
          DateFormat('EEE, d MMM').format(LocalDates.parse(_localDate)),
        ),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _statusText,
                  style: t.labelSmall?.copyWith(
                    color: _state == _SaveState.failed
                        ? AppColors.danger
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          if (_id != null)
            IconButton(
              tooltip: 'Delete entry',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
      ),
      body: _loading
          ? const LoadingState()
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.sm,
                  AppSpacing.gutter,
                  AppSpacing.xxxl,
                ),
                children: [
                  if (_prompt == null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ActionChip(
                        avatar: const Icon(Icons.lightbulb_outline, size: 18),
                        label: const Text('Use a reflection prompt'),
                        onPressed: () => _setPrompt(promptFor(_promptSeed)),
                      ),
                    )
                  else
                    AppCard(
                      accent: AppColors.brand,
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.sm,
                        AppSpacing.xs,
                        AppSpacing.sm,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _prompt!,
                              style: t.bodyLarge?.copyWith(
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Another prompt',
                            icon: const Icon(Icons.refresh),
                            onPressed: () =>
                                _setPrompt(promptFor(++_promptSeed)),
                          ),
                          IconButton(
                            tooltip: 'Remove prompt',
                            icon: const Icon(Icons.close),
                            onPressed: () => _setPrompt(null),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    key: const Key('journal-body'),
                    controller: _body,
                    autofocus: widget.entryId == null,
                    minLines: 8,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'What\'s on your mind?',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: _gratitude,
                    minLines: 1,
                    maxLines: 3,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Grateful for (optional)',
                      prefixIcon: Icon(Icons.volunteer_activism_outlined),
                    ),
                  ),
                  if (distress) ...[
                    const SizedBox(height: AppSpacing.lg),
                    const SupportCard(),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    'Autosaves as you type. Stored only on this device.',
                    style: t.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
