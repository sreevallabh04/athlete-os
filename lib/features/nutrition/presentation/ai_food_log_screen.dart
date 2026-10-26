import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/paths.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../application/ai_food_log.dart';
import '../application/providers.dart';
import '../data/indian_food_db.dart';
import '../data/mappers.dart';
import '../domain/food_log_parser.dart';
import '../domain/food_log_review.dart';
import '../domain/food_models.dart';
import '../domain/nutrients.dart';
import '../domain/nutrition_calc.dart';
import 'describe_meal_screen.dart';
import 'food_search_panel.dart';
import 'widgets/ai_log_widgets.dart';
import 'widgets/amount_sheet.dart';
import 'widgets/common.dart';
import 'widgets/nutrition_hud.dart';

/// A realistic one-day paste (also used by the screenshot tool).
const sampleDayLog =
    'Breakfast: 3 egg omelette with 2 rotis, black coffee.\n'
    'Lunch: 1 katori dal, 1 cup rice, 100g paneer bhurji, salad.\n'
    'Snack: 1 scoop whey with banana.\n'
    'Dinner: 2 besan chillas with curd';

const _examples = [
  ('Breakfast', 'Breakfast: 2 eggs, 2 rotis, black coffee'),
  ('Lunch', 'Lunch: 1 katori dal, 1 cup rice, 100g paneer'),
  ('Snack', 'Snack: 1 scoop whey with a banana'),
  ('Dinner', 'Dinner: 2 besan chillas with curd'),
];

/// Client-side ceiling for one analysis (the server deadline is ~60 s).
const aiFoodLogTimeout = Duration(seconds: 90);

enum AiLogStage { input, analysing, failed, review }

/// "Tell JARVIS what you ate": paste or dictate a whole day, get every item
/// estimated in one AI call, review with charts, then log everything at
/// once. Nothing is written before "Log all".
class AiFoodLogScreen extends ConsumerStatefulWidget {
  const AiFoodLogScreen({super.key, this.initialText, this.initialDate});

  /// `?q=` prefill (shared text).
  final String? initialText;

  /// `?date=` (YYYY-MM-DD); defaults to today.
  final String? initialDate;

  @override
  ConsumerState<AiFoodLogScreen> createState() => _AiFoodLogScreenState();
}

class _AiFoodLogScreenState extends ConsumerState<AiFoodLogScreen> {
  late final TextEditingController _ctrl;
  late String _date;
  AiLogStage _stage = AiLogStage.input;
  int _run = 0;
  bool _fast = false;
  FoodLogParseResult? _failure;
  List<ReviewItem> _items = const [];
  List<String> _unparsed = const [];
  int _dupes = 0;
  String? _provider;
  bool _saving = false;
  Timer? _ticker;
  Timer? _deadline;
  int _elapsed = 0;
  final _burst = CelebrationController();

  // Dictation.
  bool _listening = false;
  String _dictationBase = '';
  StreamController<double>? _level;

  @override
  void initState() {
    super.initState();
    final q = widget.initialText?.trim() ?? '';
    _ctrl = TextEditingController(
      text: q.length > foodLogMaxChars ? q.substring(0, foodLogMaxChars) : q,
    );
    final now = ref.read(clockProvider).now();
    final d = widget.initialDate;
    final today = LocalDates.key(now);
    _date =
        d != null &&
            RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d) &&
            d.compareTo(today) <= 0
        ? d
        : today;
    // Parse the Indian Food DB while the AI works (used to ground items).
    ref.read(indianFoodDbProvider).warmUp();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _deadline?.cancel();
    if (_listening) unawaited(ref.read(foodDictationProvider)?.cancel());
    unawaited(_level?.close());
    _ctrl.dispose();
    _burst.dispose();
    super.dispose();
  }

  DateTime get _now => ref.read(clockProvider).now();
  String get _today => LocalDates.key(_now);

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  /// Fast mode (Groq, ~9 s) is the default: live testing showed Gemini taking
  /// ~40 s for a full-day log with no better parsing. The server still falls
  /// back to Gemini if Groq is unavailable; "precise mode" asks Gemini first.
  Future<void> _analyse({bool fast = true}) async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      Haptics.warning();
      showSnack(context, 'Type or paste what you ate first.');
      return;
    }
    FocusScope.of(context).unfocus();
    await _stopDictation();
    if (!mounted) return;
    final parser = ref.read(foodLogParserProvider);
    final run = ++_run;
    _ticker?.cancel();
    setState(() {
      _stage = AiLogStage.analysing;
      _elapsed = 0;
      _failure = null;
      _fast = fast;
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
    // Own timer (not Future.timeout) so dispose/cancel can stop it.
    final timedOut = Completer<FoodLogParseResult>();
    _deadline?.cancel();
    _deadline = Timer(aiFoodLogTimeout, () {
      if (!timedOut.isCompleted) {
        timedOut.complete(
          const FoodLogParseFailure(
            'JARVIS took longer than 90 s to answer.',
            timedOut: true,
          ),
        );
      }
    });
    FoodLogParseResult res;
    try {
      res = await Future.any([
        parser.parse(text, now: _now, fast: fast),
        timedOut.future,
      ]);
    } catch (e) {
      res = FoodLogParseFailure(redactSecrets('$e'));
    }
    if (!mounted || run != _run) return;
    _deadline?.cancel();
    _ticker?.cancel();
    if (res is FoodLogParseSuccess) {
      final s = sanitizeFoodLog(res.items, now: _now, unparsed: res.unparsed);
      final db = ref.read(indianFoodDbProvider).readyIndex;
      final items = db == null ? s.items : groundWithIndianDb(s.items, db);
      if (s.items.isEmpty) {
        setState(() {
          _stage = AiLogStage.failed;
          _unparsed = s.unparsed;
          _failure = const FoodLogParseFailure(
            'JARVIS didn\'t find any food or drink in that text. Add '
            'portions like "2 rotis" or "1 katori dal" and try again.',
            retryable: false,
          );
        });
        Haptics.warning();
        return;
      }
      setState(() {
        _stage = AiLogStage.review;
        _items = items;
        _unparsed = s.unparsed;
        _dupes = s.duplicatesRemoved;
        _provider = res is FoodLogParseSuccess ? res.provider : null;
      });
      Haptics.success();
    } else {
      setState(() {
        _stage = AiLogStage.failed;
        _failure = res;
      });
      Haptics.warning();
    }
  }

  void _cancel() {
    _run++;
    _ticker?.cancel();
    _deadline?.cancel();
    Haptics.light();
    setState(() => _stage = AiLogStage.input);
    showSnack(context, 'Cancelled. Nothing was logged.');
  }

  void _backToInput() {
    Haptics.selection();
    setState(() => _stage = AiLogStage.input);
  }

  Future<void> _openOffline() async {
    await _stopDictation();
    if (!mounted) return;
    final logged = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DescribeMealScreen(
          meal: _date == _today ? MealType.forTime(_now) : MealType.lunch,
          date: _date,
          initialText: _ctrl.text.trim(),
        ),
      ),
    );
    if (logged == true && mounted) _close();
  }

  void _close() {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop(true);
    } else {
      GoRouter.maybeOf(context)?.go(AppPaths.nutrition);
    }
  }

  Future<void> _pickDate() async {
    final now = _now;
    final picked = await showDatePicker(
      context: context,
      initialDate: LocalDates.parse(_date),
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year, now.month, now.day),
    );
    if (picked != null && mounted) {
      Haptics.selection();
      setState(() => _date = LocalDates.key(picked));
    }
  }

  void _insertExample(String text) {
    final cur = _ctrl.text.trimRight();
    final next = cur.isEmpty ? text : '$cur\n$text';
    if (next.length > foodLogMaxChars) {
      Haptics.warning();
      return;
    }
    setState(() {
      _ctrl.text = next;
      _ctrl.selection = TextSelection.collapsed(offset: next.length);
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      showSnack(context, 'The clipboard has no text.');
      return;
    }
    _insertExample(
      text.length > foodLogMaxChars ? text.substring(0, foodLogMaxChars) : text,
    );
  }

  Future<void> _toggleDictation() async {
    final dictation = ref.read(foodDictationProvider);
    if (dictation == null) return;
    if (_listening) {
      await _stopDictation();
      return;
    }
    Haptics.medium();
    final base = _ctrl.text.trimRight();
    _dictationBase = base;
    unawaited(_level?.close());
    _level = StreamController<double>.broadcast();
    setState(() => _listening = true);
    final problem = await dictation.start(
      onWords: (words, isFinal) {
        if (!mounted) return;
        final w = words.trim();
        final joined = w.isEmpty
            ? _dictationBase
            : _dictationBase.isEmpty
            ? w
            : '$_dictationBase\n$w';
        final capped = joined.length > foodLogMaxChars
            ? joined.substring(0, foodLogMaxChars)
            : joined;
        setState(() {
          _ctrl.text = capped;
          _ctrl.selection = TextSelection.collapsed(offset: capped.length);
          if (isFinal) _listening = false;
        });
      },
      onLevel: (l) => _level?.add(l),
    );
    if (!mounted) return;
    if (problem != null) {
      setState(() => _listening = false);
      Haptics.warning();
      showSnack(context, problem);
    }
  }

  Future<void> _stopDictation() async {
    if (!_listening) return;
    await ref.read(foodDictationProvider)?.stop();
    if (mounted) setState(() => _listening = false);
  }

  Future<void> _edit(ReviewItem item) async {
    final res = await showHudBottomSheet<_EditResult>(
      context,
      title: 'Adjust item',
      builder: (_) => _EditItemSheet(item: item),
    );
    if (res == null || !mounted) return;
    if (res.delete) {
      _remove(item);
      return;
    }
    Haptics.success();
    setState(() {
      _items = [for (final i in _items) i.id == item.id ? res.item! : i];
    });
  }

  void _toggleDb(ReviewItem item) {
    Haptics.selection();
    setState(() {
      _items = [
        for (final i in _items) i.id == item.id ? i.withDbValues(!i.usesDb) : i,
      ];
    });
  }

  void _remove(ReviewItem item) {
    final index = _items.indexWhere((i) => i.id == item.id);
    if (index < 0) return;
    Haptics.medium();
    setState(() => _items = [..._items]..removeAt(index));
    showSnack(
      context,
      'Removed ${item.name}',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () {
          if (!mounted) return;
          setState(() {
            final list = [..._items];
            list.insert(index.clamp(0, list.length), item);
            _items = list;
          });
        },
      ),
    );
  }

  Future<void> _searchInstead(String fragment) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('Look up "$fragment"')),
          body: FoodSearchPanel(
            meal: _date == _today ? MealType.forTime(_now) : MealType.snack,
            date: _date,
            initialQuery: fragment,
          ),
        ),
      ),
    );
  }

  Future<void> _logAll() async {
    if (_items.isEmpty || _saving) return;
    setState(() => _saving = true);
    final count = _items.length;
    try {
      await logReviewedItems(
        ref.read(foodLogRepositoryProvider),
        _items,
        localDate: _date,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      Haptics.warning();
      showSnack(context, 'Couldn\'t save: ${redactSecrets('$e')}');
      return;
    }
    if (!mounted) return;
    Haptics.success();
    _burst.fire();
    ref.read(nutritionDateProvider.notifier).set(_date);
    showSnack(
      context,
      'Logged $count item${count == 1 ? '' : 's'} to '
      '${friendlyDate(_date, _today)}.',
    );
    await Future<void>.delayed(
      AppMotion.reduced(context) ? Duration.zero : AppMotion.data,
    );
    if (mounted) _close();
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final d = LocalDates.parse(_date);
    final eyebrow =
        'AI FOOD LOG · ${DateFormat('EEE d MMM').format(d).toUpperCase()}';
    final reduced = AppMotion.reduced(context);
    final Widget body = switch (_stage) {
      AiLogStage.input => _inputStage(),
      AiLogStage.analysing => _analysingStage(),
      AiLogStage.failed => _failedStage(),
      AiLogStage.review => _reviewStage(),
    };
    return AppPage(
      title: _stage == AiLogStage.review ? 'Review & log' : 'Tell JARVIS',
      eyebrow: eyebrow,
      actions: [
        if (_stage == AiLogStage.review)
          IconButton(
            tooltip: 'Edit the text',
            icon: const Icon(Icons.edit_note_rounded),
            onPressed: _backToInput,
          ),
      ],
      bottomAction: _bottomAction(),
      children: [
        AnimatedSwitcher(
          duration: reduced ? Duration.zero : AppMotion.medium,
          switchInCurve: AppMotion.emphasizedDecelerate,
          switchOutCurve: AppMotion.emphasizedAccelerate,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, 0.02),
                end: Offset.zero,
              ).animate(a),
              child: child,
            ),
          ),
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topCenter,
            children: [...previous, ?current],
          ),
          child: KeyedSubtree(key: ValueKey(_stage), child: body),
        ),
      ],
    );
  }

  Widget? _bottomAction() {
    final parser = ref.watch(foodLogParserProvider);
    switch (_stage) {
      case AiLogStage.input:
        if (!parser.isConfigured) {
          return HudButton(
            key: const Key('ai-log-offline'),
            label: 'Use offline parser',
            icon: Icons.offline_bolt_outlined,
            expand: true,
            onPressed: _openOffline,
          );
        }
        return HudButton(
          key: const Key('ai-log-analyse'),
          label: 'Analyse with JARVIS',
          icon: Icons.auto_awesome_rounded,
          expand: true,
          onPressed: _ctrl.text.trim().isEmpty ? null : () => _analyse(),
        );
      case AiLogStage.analysing:
        return HudButton.secondary(
          key: const Key('ai-log-cancel'),
          label: 'Cancel',
          icon: Icons.close_rounded,
          expand: true,
          onPressed: _cancel,
        );
      case AiLogStage.failed:
        return null;
      case AiLogStage.review:
        final n = _items.length;
        return HudButton(
          key: const Key('ai-log-commit'),
          label: n == 0
              ? 'Nothing to log'
              : 'Log all $n item${n == 1 ? '' : 's'}',
          icon: Icons.check_rounded,
          expand: true,
          loading: _saving,
          onPressed: n == 0 || _saving ? null : _logAll,
        );
    }
  }

  // ---------------------------------------------------------------- input --

  Widget _inputStage() {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final parser = ref.watch(foodLogParserProvider);
    final dictation = ref.watch(foodDictationProvider);
    final len = _ctrl.text.length;
    final near = len > foodLogMaxChars * 0.9;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Paste or dictate everything you ate. JARVIS splits it into meals, '
          'estimates every item and shows the totals before anything is '
          'logged.',
          style: t.bodyMedium?.copyWith(color: hud.textMuted),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (!parser.isConfigured) ...[
          const NoticeBanner(
            message:
                'AI is offline in this build, so JARVIS can\'t read meal '
                'text. Use the offline parser: it matches your saved foods '
                'on this phone.',
            icon: Icons.cloud_off_outlined,
            color: AppColors.warning,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        AppCard(
          brackets: true,
          glow: _listening,
          accent: _listening ? hud.accent : null,
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
                  GlowIcon(
                    Icons.auto_awesome_rounded,
                    size: 14,
                    color: hud.accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _listening ? 'LISTENING…' : 'WHAT DID YOU EAT?',
                      style: hud.label(size: 11),
                    ),
                  ),
                  Text(
                    '${Fmt.integer(len)} / ${Fmt.integer(foodLogMaxChars)}',
                    style: hud.mono(
                      size: 10,
                      color: near ? hud.ink(AppColors.warning) : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              TextField(
                key: const Key('ai-log-field'),
                controller: _ctrl,
                minLines: 7,
                maxLines: 14,
                maxLength: foodLogMaxChars,
                maxLengthEnforcement: MaxLengthEnforcement.enforced,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                style: t.bodyLarge?.copyWith(height: 1.45),
                decoration: const InputDecoration(
                  hintText:
                      'Paste or type everything you ate today…\n\n'
                      'Breakfast: 2 eggs, 2 rotis\n'
                      'Lunch: 1 katori dal, rice, paneer\n'
                      '5pm: whey shake',
                  hintMaxLines: 6,
                  counterText: '',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
                onChanged: (_) => setState(() {}),
              ),
              Divider(height: 1, color: hud.hairline.withValues(alpha: 0.15)),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  if (dictation != null) ...[
                    _MicButton(
                      listening: _listening,
                      level: _level?.stream,
                      onTap: _toggleDictation,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                  ],
                  Expanded(
                    child: Text(
                      dictation == null
                          ? 'Bullets, Hinglish and times all work.'
                          : _listening
                          ? 'Speak naturally. Tap to stop.'
                          : 'Tap the mic to dictate.',
                      style: t.bodySmall?.copyWith(color: hud.textMuted),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Paste',
                    icon: const Icon(Icons.content_paste_rounded, size: 20),
                    onPressed: _paste,
                  ),
                  if (len > 0)
                    IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.backspace_outlined, size: 20),
                      onPressed: () {
                        Haptics.light();
                        setState(_ctrl.clear);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        const HudCaption('Add a line'),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final (label, text) in _examples)
              _ExampleChip(
                label: label,
                text: text,
                onTap: () => _insertExample(text),
              ),
            _ExampleChip(
              label: 'Full day',
              text: sampleDayLog,
              icon: Icons.calendar_view_day_rounded,
              onTap: () => _insertExample(sampleDayLog),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        _DateRow(
          label: friendlyDate(_date, _today),
          isToday: _date == _today,
          onTap: _pickDate,
        ),
        const SizedBox(height: AppSpacing.lg),
        _PrivacyNote(configured: parser.isConfigured),
        if (parser.isConfigured) ...[
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: TextButton.icon(
              onPressed: _openOffline,
              icon: const Icon(Icons.offline_bolt_outlined, size: 16),
              label: const Text('No signal? Use the offline parser'),
            ),
          ),
        ],
      ],
    );
  }

  // ------------------------------------------------------------ analysing --

  static const _statuses = [
    'Sending your log to JARVIS…',
    'Splitting it into meals and items…',
    'Estimating portions: katori, roti, scoop…',
    'Working out calories and macros…',
    'Checking the numbers add up…',
  ];

  Widget _analysingStage() {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final i = (_elapsed ~/ 3).clamp(0, _statuses.length - 1);
    final preview = _ctrl.text.trim().split('\n').take(4).join('\n');
    final mm = (_elapsed ~/ 60).toString().padLeft(2, '0');
    final ss = (_elapsed % 60).toString().padLeft(2, '0');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.lg),
        const Center(
          child: JarvisOrb(
            state: OrbState.thinking,
            size: 168,
            semanticLabel: 'JARVIS is analysing your food log',
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Center(
          child: Text(
            _fast ? 'ANALYSING · FAST MODE' : 'ANALYSING',
            style: hud.label(size: 12, color: hud.accentInk),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        AnimatedSwitcher(
          duration: AppMotion.reduced(context)
              ? Duration.zero
              : AppMotion.medium,
          child: Text(
            _statuses[i],
            key: ValueKey(i),
            textAlign: TextAlign.center,
            style: t.titleMedium,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Center(child: Text('T+ $mm:$ss', style: hud.mono(size: 11))),
        const SizedBox(height: AppSpacing.xl),
        GlassPanel(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('INPUT', style: hud.label(size: 10)),
              const SizedBox(height: 6),
              Text(
                preview,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: t.bodySmall?.copyWith(color: hud.textMuted, height: 1.4),
              ),
              const SizedBox(height: AppSpacing.md),
              const ScanlineLoader(lines: 3),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          _elapsed >= 15
              ? 'Long logs can take 20–40 s on Gemini. You can keep waiting '
                    'or cancel; nothing is logged until you review.'
              : 'Only the text above is sent. Nothing is logged until you '
                    'review it.',
          textAlign: TextAlign.center,
          style: t.bodySmall?.copyWith(color: hud.textMuted),
        ),
        if (_elapsed >= 15 &&
            !_fast &&
            ref.read(foodLogParserProvider).supportsFastMode) ...[
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: TextButton.icon(
              key: const Key('ai-log-switch-fast'),
              onPressed: () => _analyse(fast: true),
              icon: const Icon(Icons.bolt_rounded, size: 18),
              label: const Text('Switch to fast mode (Groq)'),
            ),
          ),
        ],
      ],
    );
  }

  // --------------------------------------------------------------- failed --

  Widget _failedStage() {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final parser = ref.read(foodLogParserProvider);
    final f = _failure;
    final unavailable = f is FoodLogParseUnavailable;
    final message = switch (f) {
      FoodLogParseUnavailable(:final reason) => reason,
      FoodLogParseFailure(:final message) => message,
      _ => 'Something went wrong.',
    };
    final timedOut = f is FoodLogParseFailure && f.timedOut;
    final retryable = f is FoodLogParseFailure && f.retryable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ErrorState(
          eyebrow: unavailable ? 'AI OFFLINE' : 'ANALYSIS FAILED',
          title: unavailable
              ? 'JARVIS can\'t read meals right now'
              : timedOut
              ? 'That took too long'
              : 'Couldn\'t read that log',
          message: redactSecrets(message),
        ),
        const SizedBox(height: AppSpacing.md),
        if (retryable)
          HudButton(
            key: const Key('ai-log-retry'),
            label: 'Retry',
            icon: Icons.refresh_rounded,
            expand: true,
            onPressed: () => _analyse(fast: _fast),
          ),
        if (retryable && parser.supportsFastMode && _fast) ...[
          const SizedBox(height: AppSpacing.sm),
          HudButton.secondary(
            key: const Key('ai-log-precise'),
            label: 'Try precise mode (Gemini)',
            icon: Icons.psychology_alt_rounded,
            expand: true,
            onPressed: () => _analyse(fast: false),
          ),
        ],
        if (retryable && parser.supportsFastMode && !_fast) ...[
          const SizedBox(height: AppSpacing.sm),
          HudButton.secondary(
            key: const Key('ai-log-fast'),
            label: 'Try fast mode (Groq)',
            icon: Icons.bolt_rounded,
            expand: true,
            onPressed: () => _analyse(fast: true),
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        HudButton.secondary(
          label: 'Edit the text',
          icon: Icons.edit_note_rounded,
          expand: true,
          onPressed: _backToInput,
        ),
        const SizedBox(height: AppSpacing.sm),
        HudButton.ghost(
          label: 'Use offline parser',
          icon: Icons.offline_bolt_outlined,
          expand: true,
          onPressed: _openOffline,
        ),
        if (_unparsed.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          _UnparsedPanel(fragments: _unparsed, onSearch: _searchInstead),
        ],
        const SizedBox(height: AppSpacing.md),
        Text(
          'Nothing was logged.',
          textAlign: TextAlign.center,
          style: t.bodySmall?.copyWith(color: hud.textMuted),
        ),
      ],
    );
  }

  // --------------------------------------------------------------- review --

  Widget _reviewStage() {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final summary = FoodLogSummary.of(_items);
    final targets = ref.watch(nutritionTargetsProvider).value;
    final entries = ref.watch(dayEntriesProvider(_date)).value;
    final existing = entries == null
        ? null
        : DayTotals.fromLines(entries.map((e) => e.line)).total;
    final impact = targets == null || existing == null
        ? null
        : FoodLogImpact.compute(
            existing: existing,
            added: summary.total,
            targets: targets,
          );
    final isToday = _date == _today;
    final adjusted = _items
        .where((i) => i.flags.contains(ReviewFlag.kcalRecomputed))
        .length;
    final sections = <Widget>[
      _HeroSummary(summary: summary, burst: _burst, provider: _provider),
      if (_items.isNotEmpty) ...[
        const SectionHeader(
          'Calories by item',
          subtitle: 'Sorted high to low · colour = meal',
        ),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MealLegend(meals: summary.meals),
              const SizedBox(height: AppSpacing.md),
              ItemCaloriesChart(items: _items),
            ],
          ),
        ),
      ],
      if (impact != null && _items.isNotEmpty) ...[
        SectionHeader(
          isToday
              ? 'Impact on today'
              : 'Impact on ${friendlyDate(_date, _today)}',
          subtitle: existing!.calories > 0
              ? 'Already logged ${Fmt.kcal(existing.calories)}'
              : 'Nothing logged yet that day',
        ),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ImpactBar(
                label: 'CALORIES',
                line: impact.calories,
                color: AppColors.calories,
                unit: 'kcal',
              ),
              const SizedBox(height: AppSpacing.lg),
              ImpactBar(
                label: 'PROTEIN',
                line: impact.protein,
                color: AppColors.protein,
                unit: 'g',
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: ImpactBar(
                      label: 'CARBS',
                      line: impact.carbs,
                      color: AppColors.carbs,
                      unit: 'g',
                      compact: true,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: ImpactBar(
                      label: 'FAT',
                      line: impact.fat,
                      color: AppColors.fat,
                      unit: 'g',
                      compact: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
      SectionHeader(
        'Items',
        subtitle: 'Tap to adjust · swipe to remove',
        action: 'Edit text',
        onAction: _backToInput,
      ),
      if (_items.any((i) => i.grounding != null))
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: NoticeBanner(
            key: const Key('ai-db-grounded'),
            icon: Icons.menu_book_rounded,
            color: AppColors.success,
            message:
                '${_items.where((i) => i.usesDb).length} of ${_items.length} '
                'items use the Indian Food DB: table values per 100 g × '
                "JARVIS's grams. Tap \"Use AI estimate\" on any to switch.",
          ),
        ),
      if (_items.isEmpty)
        const EmptyState(
          compact: true,
          icon: Icons.remove_shopping_cart_outlined,
          title: 'All items removed',
          message: 'Edit the text to analyse again, or undo a removal.',
        ),
      for (final m in summary.meals) ...[
        _MealHeader(
          meal: m,
          nutrients: summary.byMeal[m]!,
          count: _items.where((i) => i.mealType == m).length,
        ),
        for (final item in _items.where((i) => i.mealType == m))
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Dismissible(
              key: ValueKey('ai-item-${item.id}'),
              direction: DismissDirection.endToStart,
              background: const _SwipeBackground(),
              onDismissed: (_) => _remove(item),
              child: _ItemRow(
                item: item,
                onTap: () => _edit(item),
                onToggleDb: () => _toggleDb(item),
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
      ],
      if (_unparsed.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.sm),
        _UnparsedPanel(fragments: _unparsed, onSearch: _searchInstead),
      ],
      const SizedBox(height: AppSpacing.lg),
      if (adjusted > 0 || _dupes > 0 || summary.lowConfidenceCount > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: NoticeBanner(
            icon: Icons.fact_check_outlined,
            color: AppColors.warning,
            message: [
              if (summary.lowConfidenceCount > 0)
                '${summary.lowConfidenceCount} low-confidence '
                    'item${summary.lowConfidenceCount == 1 ? '' : 's'} '
                    '(red dot): check the portion.',
              if (adjusted > 0)
                'kcal recalculated from macros for $adjusted '
                    'item${adjusted == 1 ? '' : 's'}.',
              if (_dupes > 0)
                '$_dupes duplicate line${_dupes == 1 ? '' : 's'} removed.',
            ].join(' '),
          ),
        ),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded, size: 14, color: hud.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'AI estimates from the text you sent'
              '${_provider == null ? '' : ' (${_provider!})'}. Edit anything '
              'before logging. Entries are saved on this phone as ESTIMATE.',
              style: t.bodySmall?.copyWith(color: hud.textMuted),
            ),
          ),
        ],
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: staggered(sections),
    );
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

class _HeroSummary extends StatelessWidget {
  const _HeroSummary({
    required this.summary,
    required this.burst,
    required this.provider,
  });
  final FoodLogSummary summary;
  final CelebrationController burst;
  final String? provider;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final n = summary.total;
    Widget macro(String label, double v, Color c) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 10,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  color: c,
                  boxShadow: [
                    BoxShadow(
                      color: c.withValues(alpha: 0.6 * hud.glowStrength),
                      blurRadius: 5,
                    ),
                  ],
                ),
              ),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: hud.label(size: 10),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          AnimatedTicker(
            '${Fmt.integer(v)} g',
            style: hud.number(size: 20, color: hud.text),
          ),
        ],
      ),
    );
    return CelebrationBurst(
      controller: burst,
      color: AppColors.success,
      child: AppCard(
        brackets: true,
        glow: true,
        accent: AppColors.calories,
        semanticLabel:
            'Total ${macroSummary(n)}, ${summary.count} items, estimate',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const EstimateBadge(),
                      const SizedBox(height: AppSpacing.sm),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: AnimatedTicker(
                          Fmt.integer(n.calories),
                          style: hud.number(size: 52, color: hud.text),
                        ),
                      ),
                      Text(
                        'KCAL · ${summary.count} '
                        'ITEM${summary.count == 1 ? '' : 'S'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: hud.label(
                          size: 11,
                          color: hud.ink(AppColors.calories),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      for (final m in summary.meals)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Row(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: mealColor(m),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  m.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: hud.textMuted),
                                ),
                              ),
                              Text(
                                Fmt.integer(summary.byMeal[m]!.calories),
                                style: hud.mono(size: 10.5, color: hud.text),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Column(
                  children: [
                    MacroDonut(split: summary.split, size: 124),
                    const SizedBox(height: AppSpacing.sm),
                    MacroLegend(split: summary.split),
                  ],
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Divider(height: 1, color: hud.hairline.withValues(alpha: 0.15)),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                macro('PROTEIN', n.protein, AppColors.protein),
                macro('CARBS', n.carbs, AppColors.carbs),
                macro('FAT', n.fat, AppColors.fat),
                if (n.fiber != null) macro('FIBER', n.fiber!, AppColors.fiber),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MealHeader extends StatelessWidget {
  const _MealHeader({
    required this.meal,
    required this.nutrients,
    required this.count,
  });
  final MealType meal;
  final Nutrients nutrients;
  final int count;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final c = mealColor(meal);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.sm),
      child: Row(
        children: [
          Icon(mealIcon(meal), size: 16, color: c),
          const SizedBox(width: AppSpacing.sm),
          Text(
            meal.label.toUpperCase(),
            style: hud.label(size: 12, color: hud.text),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [c.withValues(alpha: 0.5), c.withValues(alpha: 0)],
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            '$count · ${Fmt.kcal(nutrients.calories)}',
            style: hud.mono(size: 10.5),
          ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.onTap,
    required this.onToggleDb,
  });
  final ReviewItem item;
  final VoidCallback onTap;
  final VoidCallback onToggleDb;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final n = item.nutrients;
    final db = item.grounding;
    final usesDb = item.usesDb;
    final recomputed =
        !usesDb && item.flags.contains(ReviewFlag.kcalRecomputed);
    return AppCard(
      animateEntrance: false,
      onTap: onTap,
      semanticLabel:
          '${item.name}, ${portionLabel(item)}, ${macroSummary(n)}, '
          '${usesDb ? 'from Indian Food DB' : 'estimate, ${confidenceLabel(item.confidence)}'}. '
          'Tap to adjust.',
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6, right: AppSpacing.sm),
                child: ConfidenceDot(confidence: item.confidence),
              ),
              Expanded(
                child: Text(
                  item.name,
                  style: t.titleSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: usesDb
                    ? const _DbBadge()
                    : const EstimateBadge(label: 'EST'),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: Fmt.integer(n.calories),
                      style: hud.number(size: 20, color: hud.text),
                    ),
                    TextSpan(text: ' kcal', style: hud.mono(size: 10)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    portionLabel(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(color: hud.textMuted),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(compactMacros(item), style: hud.mono(size: 10.5)),
              ],
            ),
          ),
          if (item.note != null || recomputed) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.info_outline_rounded,
                      size: 12,
                      color: hud.textMuted,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      [
                        ?item.note,
                        if (recomputed) 'kcal recalculated from macros',
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(
                        color: hud.textMuted,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (db != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Row(
                children: [
                  Icon(
                    usesDb ? Icons.menu_book_rounded : Icons.auto_awesome,
                    size: 12,
                    color: hud.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      usesDb
                          ? 'matched: ${db.dish.name}'
                          : 'AI estimate (DB match: ${db.dish.name})',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(color: hud.textMuted),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  TextButton(
                    key: ValueKey('ai-db-toggle-${item.id}'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(48, 36),
                    ),
                    onPressed: onToggleDb,
                    child: Text(usesDb ? 'Use AI estimate' : 'Use DB values'),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: MacroSplitBar(
              protein: n.protein,
              carbs: n.carbs,
              fat: n.fat,
              height: 2.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small "INDIAN FOOD DB" pill for items grounded in the table.
class _DbBadge extends StatelessWidget {
  const _DbBadge();

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.xs),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.55)),
        color: AppColors.success.withValues(alpha: 0.12),
      ),
      child: Text(
        'INDIAN FOOD DB',
        style: hud.label(size: 9, color: hud.ink(AppColors.success)),
      ),
    );
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.red.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: AppColors.red.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'REMOVE',
            style: context.hud.label(
              size: 11,
              color: context.hud.ink(AppColors.red),
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            Icons.delete_outline_rounded,
            color: context.hud.ink(AppColors.red),
          ),
        ],
      ),
    );
  }
}

class _UnparsedPanel extends StatelessWidget {
  const _UnparsedPanel({required this.fragments, required this.onSearch});
  final List<String> fragments;
  final ValueChanged<String> onSearch;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return GlassPanel(
      accent: AppColors.warning,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.help_outline_rounded,
                size: 16,
                color: hud.ink(AppColors.warning),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'JARVIS couldn\'t place ${fragments.length == 1 ? 'this' : 'these'}',
                  style: t.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: Text(
              'Not logged. Search the food database instead if they were food.',
              style: t.bodySmall?.copyWith(color: hud.textMuted),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          for (final f in fragments)
            Row(
              children: [
                Expanded(
                  child: Text(
                    '“$f”',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodyMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => onSearch(f),
                  child: const Text('Search instead'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.label,
    required this.isToday,
    required this.onTap,
  });
  final String label;
  final bool isToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return AppCard(
      onTap: onTap,
      semanticLabel: 'Logging for $label. Change date',
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          GlowIcon(Icons.event_rounded, size: 18, color: hud.accent),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('LOGGING FOR', style: hud.label(size: 10)),
                const SizedBox(height: 2),
                Text(label, style: t.titleSmall),
              ],
            ),
          ),
          Text(
            isToday ? 'Change' : 'Change date',
            style: t.labelLarge?.copyWith(color: hud.accentInk),
          ),
          Icon(Icons.chevron_right_rounded, color: hud.accentInk),
        ],
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote({required this.configured});
  final bool configured;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline_rounded, size: 14, color: hud.textMuted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            configured
                ? 'Only this text goes to the AI to estimate values; your log '
                      'stays on this phone. Values are estimates you can edit '
                      'before anything is saved.'
                : 'Nothing is sent anywhere while AI is offline.',
            style: t.bodySmall?.copyWith(color: hud.textMuted),
          ),
        ),
      ],
    );
  }
}

class _ExampleChip extends StatelessWidget {
  const _ExampleChip({
    required this.label,
    required this.text,
    required this.onTap,
    this.icon = Icons.add_rounded,
  });
  final String label;
  final String text;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Semantics(
      button: true,
      label: 'Add example: $text',
      excludeSemantics: true,
      onTap: onTap,
      child: PressableScale(
        onTap: onTap,
        haptic: PressHaptic.selection,
        pressedScale: 0.95,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.sm),
            color: hud.accent.withValues(alpha: 0.06),
            border: Border.all(color: hud.accent.withValues(alpha: 0.22)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: hud.accentInk),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: hud.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.listening,
    required this.level,
    required this.onTap,
  });
  final bool listening;
  final Stream<double>? level;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final label = listening ? 'Stop dictation' : 'Dictate what you ate';
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: PressableScale(
        haptic: PressHaptic.none,
        onTap: onTap,
        child: SizedBox.square(
          dimension: 48,
          child: listening
              ? Stack(
                  alignment: Alignment.center,
                  children: [
                    JarvisOrb(
                      state: OrbState.listening,
                      level: level,
                      size: 48,
                      fps: 30,
                    ),
                    const Icon(
                      Icons.stop_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ],
                )
              : Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hud.accent.withValues(alpha: 0.1),
                    border: Border.all(
                      color: hud.accent.withValues(alpha: 0.55),
                    ),
                    boxShadow: AppGlows.soft(
                      hud.accent,
                      strength: hud.glowStrength * 0.6,
                    ),
                  ),
                  child: Icon(
                    Icons.mic_rounded,
                    color: hud.accentInk,
                    size: 22,
                  ),
                ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Edit sheet
// ---------------------------------------------------------------------------

class _EditResult {
  const _EditResult.save(ReviewItem this.item) : delete = false;
  const _EditResult.delete() : item = null, delete = true;
  final ReviewItem? item;
  final bool delete;
}

class _EditItemSheet extends StatefulWidget {
  const _EditItemSheet({required this.item});
  final ReviewItem item;

  @override
  State<_EditItemSheet> createState() => _EditItemSheetState();
}

class _EditItemSheetState extends State<_EditItemSheet> {
  late final _name = TextEditingController(text: widget.item.name);
  late final _gramsCtrl = TextEditingController(
    text: widget.item.grams == null ? '' : plainNum(widget.item.grams!),
  );
  late MealType _meal = widget.item.mealType;
  late double? _grams = widget.item.grams;

  @override
  void dispose() {
    _name.dispose();
    _gramsCtrl.dispose();
    super.dispose();
  }

  double get _step {
    final g = _grams ?? 100;
    if (g < 60) return 5;
    if (g < 300) return 10;
    return 25;
  }

  void _nudge(int dir) {
    final g = _grams;
    if (g == null) return;
    final next = (g + dir * _step).clamp(5.0, FoodLogLimits.grams);
    Haptics.selection();
    setState(() {
      _grams = next.toDouble();
      _gramsCtrl.text = plainNum(_grams!);
    });
  }

  ReviewItem get _preview {
    var i = widget.item;
    final g = _grams;
    if (g != null && g > 0 && g != i.grams) i = i.scaledToGrams(g);
    return i;
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      Haptics.warning();
      return;
    }
    final p = _preview;
    final changed =
        name != widget.item.name ||
        _meal != widget.item.mealType ||
        p.grams != widget.item.grams;
    Navigator.of(context).pop(
      _EditResult.save(
        p.copyWith(
          name: name,
          mealType: _meal,
          flags: changed ? {...p.flags, ReviewFlag.edited} : p.flags,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    final t = Theme.of(context).textTheme;
    final p = _preview;
    final hasGrams = widget.item.grams != null && widget.item.grams! > 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.sm,
        AppSpacing.gutter,
        AppSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('ai-edit-name'),
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.md),
            if (hasGrams) ...[
              Text('AMOUNT', style: hud.label(size: 10.5)),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: 'Less',
                    onPressed: () => _nudge(-1),
                    icon: const Icon(Icons.remove_rounded),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      key: const Key('ai-edit-grams'),
                      controller: _gramsCtrl,
                      textAlign: TextAlign.center,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: hud.number(size: 24, color: hud.text),
                      decoration: const InputDecoration(suffixText: 'g'),
                      onChanged: (v) {
                        final g = double.tryParse(v.replaceAll(',', '.'));
                        setState(
                          () => _grams = g != null && g > 0 ? g : _grams,
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  IconButton.filledTonal(
                    tooltip: 'More',
                    onPressed: () => _nudge(1),
                    icon: const Icon(Icons.add_rounded),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Macros scale with the amount'
                '${widget.item.quantity == null ? '' : ' (was ${widget.item.quantity})'}.',
                style: t.bodySmall?.copyWith(color: hud.textMuted),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            NutrientPreview(nutrients: p.nutrients, estimate: true),
            const SizedBox(height: AppSpacing.md),
            MealPicker(
              value: _meal,
              onChanged: (m) {
                Haptics.selection();
                setState(() => _meal = m);
              },
            ),
            if (widget.item.note != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                'JARVIS assumed: ${widget.item.note}',
                style: t.bodySmall?.copyWith(color: hud.textMuted),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: HudButton(
                    label: 'Remove',
                    icon: Icons.delete_outline_rounded,
                    variant: HudButtonVariant.danger,
                    onPressed: () =>
                        Navigator.of(context).pop(const _EditResult.delete()),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: HudButton(
                    key: const Key('ai-edit-save'),
                    label: 'Save',
                    icon: Icons.check_rounded,
                    onPressed: _name.text.trim().isEmpty ? null : _save,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
