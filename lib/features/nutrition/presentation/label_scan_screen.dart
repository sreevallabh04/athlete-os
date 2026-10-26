import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../../../data/repositories/settings_repository.dart';
import '../application/providers.dart';
import '../data/label_photo.dart';
import '../domain/food_models.dart';
import '../domain/nutrition_label.dart';
import 'custom_food_screen.dart';
import 'food_actions.dart';
import 'widgets/common.dart';
import 'widgets/nutrition_hud.dart';
import 'widgets/scan_sweep.dart';

/// What the label scan produced: the saved food, and whether it was also
/// logged from this screen.
class LabelScanOutcome {
  const LabelScanOutcome(this.food, {this.logged = false});
  final Food food;
  final bool logged;
}

/// Label field ids (match the `read_nutrition_label` schema paths).
abstract final class LabelFields {
  static const nutrients = [
    'kcal',
    'protein_g',
    'carbs_g',
    'fat_g',
    'fiber_g',
    'sugar_g',
  ];
  static const core = ['kcal', 'protein_g', 'carbs_g', 'fat_g'];
  static const servingSize = 'serving.size_g';

  static String label(String key) => switch (key) {
    'kcal' => 'Energy',
    'protein_g' => 'Protein',
    'carbs_g' => 'Total carbs',
    'fat_g' => 'Total fat',
    'fiber_g' => 'Dietary fibre',
    'sugar_g' => 'Total sugars',
    _ => key,
  };

  /// "per_100g.fiber_g" → "Dietary fibre (per 100 g)".
  static String human(String id, {String unit = 'g'}) {
    final dot = id.indexOf('.');
    if (dot < 0) return label(id);
    final col = id.substring(0, dot);
    final key = id.substring(dot + 1);
    if (id == servingSize) return 'Serving size';
    final colLabel = col == 'serving' ? 'per serving' : 'per 100 $unit';
    return '${label(key)} ($colLabel)';
  }
}

/// "Scan nutrition label": photo of the pack's nutrition table → the AI
/// transcribes it → the user reviews/edits every value → saved to My foods
/// (source `custom`, verification `user_entered`) and optionally logged.
///
/// Falls back to the manual custom-food form when the AI is unavailable.
class LabelScanScreen extends ConsumerStatefulWidget {
  const LabelScanScreen({
    super.key,
    this.initialName,
    this.barcode,
    this.meal,
    this.date,
  });

  final String? initialName;
  final String? barcode;

  /// Meal for "Save & log now" (defaults to the meal for the current time).
  final MealType? meal;

  /// YYYY-MM-DD for "Save & log now" (defaults to today).
  final String? date;

  @override
  ConsumerState<LabelScanScreen> createState() => _LabelScanScreenState();
}

enum _Stage { capture, reading, review }

class _LabelScanScreenState extends ConsumerState<LabelScanScreen> {
  _Stage _stage = _Stage.capture;
  Uint8List? _photo;
  String? _message;
  NutritionLabelReading? _reading;
  String? _provider;
  bool _saving = false;
  bool _submitted = false;
  Map<String, String> _errors = const {};
  String _unit = 'g';

  final _name = TextEditingController();
  final _brand = TextEditingController();
  final _barcode = TextEditingController();
  final _size = TextEditingController();
  late final Map<String, TextEditingController> _p100 = {
    for (final k in LabelFields.nutrients) k: TextEditingController(),
  };
  late final Map<String, TextEditingController> _serv = {
    for (final k in LabelFields.nutrients) k: TextEditingController(),
  };

  @override
  void initState() {
    super.initState();
    _name.text = widget.initialName?.trim() ?? '';
    _barcode.text = widget.barcode?.trim() ?? '';
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _brand,
      _barcode,
      _size,
      ..._p100.values,
      ..._serv.values,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  MealType get _meal =>
      widget.meal ?? MealType.forTime(ref.read(clockProvider).now());

  String get _date {
    final d = widget.date;
    if (d != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d)) return d;
    return LocalDates.key(ref.read(clockProvider).now());
  }

  // -------------------------------------------------------------------------
  // Capture + read
  // -------------------------------------------------------------------------

  Future<void> _setConsent(bool v) =>
      ref.read(settingsRepositoryProvider).set(SettingKeys.aiPhotoConsent, v);

  Future<void> _pick(ImageSource source) async {
    LabelPhoto? photo;
    try {
      photo = await ref.read(labelPhotoPickerProvider)(source);
    } on LabelPhotoException catch (e) {
      if (mounted) setState(() => _message = e.message);
      Haptics.warning();
      return;
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = 'Could not get a photo: ${redactSecrets('$e')}',
        );
      }
      return;
    }
    if (photo == null || !mounted) return;
    setState(() {
      _photo = photo!.bytes;
      _stage = _Stage.reading;
      _message = null;
    });
    final result = await ref
        .read(nutritionLabelReaderProvider)
        .read(photo.bytes, mimeType: photo.mimeType);
    if (!mounted) return;
    switch (result) {
      case LabelReadSuccess(:final reading, :final provider):
        _apply(reading);
        setState(() {
          _reading = reading;
          _provider = provider;
          _stage = _Stage.review;
        });
        Haptics.success();
      case LabelReadUnavailable(:final reason):
        setState(() {
          _stage = _Stage.capture;
          _message = reason;
        });
        Haptics.warning();
      case LabelReadFailure(:final message):
        setState(() {
          _stage = _Stage.capture;
          _message = redactSecrets(message);
        });
        Haptics.warning();
    }
  }

  void _apply(NutritionLabelReading r) {
    String n(double? v) => v == null ? '' : plainNum(v);
    if (r.productName != null) _name.text = r.productName!;
    if (r.brand != null) _brand.text = r.brand!;
    _unit = r.unit;
    _size.text = n(r.servingSize);
    void fill(Map<String, TextEditingController> c, LabelColumn col) {
      c['kcal']!.text = n(col.kcal);
      c['protein_g']!.text = n(col.protein);
      c['carbs_g']!.text = n(col.carbs);
      c['fat_g']!.text = n(col.fat);
      c['fiber_g']!.text = n(col.fiber);
      c['sugar_g']!.text = n(col.sugar);
    }

    fill(_p100, r.per100);
    fill(_serv, r.serving);
    _submitted = false;
    _errors = const {};
  }

  Future<void> _manual() async {
    final food = await Navigator.of(context).push<Food>(
      MaterialPageRoute(
        builder: (_) => CustomFoodScreen(
          initialName: _name.text.trim().isEmpty ? null : _name.text.trim(),
          barcode: _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
        ),
      ),
    );
    if (food != null && mounted) {
      Navigator.of(context).pop(LabelScanOutcome(food));
    }
  }

  // -------------------------------------------------------------------------
  // Review: values, flags, validation
  // -------------------------------------------------------------------------

  static double? _d(TextEditingController c) {
    final t = c.text.trim().replaceAll(',', '.');
    if (t.isEmpty) return null;
    final v = double.tryParse(t);
    return v != null && v.isFinite ? v : null;
  }

  LabelColumn _column(Map<String, TextEditingController> c) => LabelColumn(
    kcal: _d(c['kcal']!),
    protein: _d(c['protein_g']!),
    carbs: _d(c['carbs_g']!),
    fat: _d(c['fat_g']!),
    fiber: _d(c['fiber_g']!),
    sugar: _d(c['sugar_g']!),
  );

  LabelColumn get _per100 {
    final c = _column(_p100);
    final r = _reading;
    // Keep the kJ flag while the converted value is untouched.
    final fromKj =
        r != null && r.per100.energyFromKj && c.kcal == r.per100.kcal;
    return fromKj ? _withKj(c) : c;
  }

  LabelColumn get _serving {
    final c = _column(_serv);
    final r = _reading;
    final fromKj =
        r != null && r.serving.energyFromKj && c.kcal == r.serving.kcal;
    return fromKj ? _withKj(c) : c;
  }

  static LabelColumn _withKj(LabelColumn c) => LabelColumn(
    kcal: c.kcal,
    protein: c.protein,
    carbs: c.carbs,
    fat: c.fat,
    fiber: c.fiber,
    sugar: c.sugar,
    energyFromKj: true,
  );

  /// Field ids the AI could not read, plus core values still empty in a
  /// column that has other values.
  Set<String> get _flagged {
    final out = <String>{};
    final unreadable = _reading?.unreadableFields ?? const <String>[];
    for (final u in unreadable) {
      final id = u.trim();
      if (id.contains('.')) {
        out.add(id);
      } else {
        // Bare key ("fiber_g"): flag it in both columns.
        out
          ..add('per_100g.$id')
          ..add('serving.$id');
      }
    }
    void missing(String prefix, Map<String, TextEditingController> c) {
      final any = c.values.any((x) => x.text.trim().isNotEmpty);
      if (!any) return;
      for (final k in LabelFields.core) {
        if (c[k]!.text.trim().isEmpty) out.add('$prefix.$k');
      }
    }

    if (_reading != null) {
      missing('per_100g', _p100);
      missing('serving', _serv);
    }
    return out;
  }

  Map<String, String> _validate() {
    final e = <String, String>{};
    if (_name.text.trim().isEmpty) e['name'] = 'Enter a name';
    if (_name.text.trim().length > 120) e['name'] = 'Name is too long';
    final code = _barcode.text.trim();
    if (code.isNotEmpty && !RegExp(r'^\d{6,14}$').hasMatch(code)) {
      e['barcode'] = 'Barcodes are 6–14 digits';
    }
    void numbers(String prefix, Map<String, TextEditingController> c) {
      for (final entry in c.entries) {
        final t = entry.value.text.trim();
        if (t.isEmpty) continue;
        final v = _d(entry.value);
        if (v == null) {
          e['$prefix.${entry.key}'] = 'Enter a number';
        } else if (v < 0) {
          e['$prefix.${entry.key}'] = 'Must be 0 or more';
        }
      }
    }

    numbers('per_100g', _p100);
    numbers('serving', _serv);
    final p = _per100;
    if ((p.kcal ?? 0) > 950) {
      e['per_100g.kcal'] = 'Over 900 kcal per 100 $_unit is impossible';
    }
    for (final (k, v) in [
      ('protein_g', p.protein),
      ('carbs_g', p.carbs),
      ('fat_g', p.fat),
      ('fiber_g', p.fiber),
      ('sugar_g', p.sugar),
    ]) {
      if (v != null && v > 100) {
        e['per_100g.$k'] = 'Can\'t exceed 100 g per 100 $_unit';
      }
    }
    final sizeText = _size.text.trim();
    if (sizeText.isNotEmpty) {
      final s = _d(_size);
      if (s == null || s <= 0 || s > 5000) {
        e[LabelFields.servingSize] = 'Enter a size in $_unit';
      }
    }
    final s = _serving;
    if (!p.isComplete && !s.isComplete) {
      e['basis'] =
          'Fill energy, protein, carbs and fat for at least one column '
          '(per 100 $_unit or per serving).';
    } else if (!p.isComplete && s.isComplete && _d(_size) == null) {
      // Allowed (logged by servings only) — no error.
    }
    return e;
  }

  /// Non-blocking sanity checks shown above the form.
  List<String> get _warnings {
    final out = <String>[];
    void check(String col, LabelColumn c) {
      final dev = macroEnergyDeviation(
        kcal: c.kcal,
        protein: c.protein,
        carbs: c.carbs,
        fat: c.fat,
      );
      if (dev != null && dev > macroEnergyTolerance) {
        final macro = (c.protein! * 4 + c.carbs! * 4 + c.fat! * 9).round();
        out.add(
          '$col: label says ${c.kcal!.round()} kcal but protein, carbs and '
          'fat add up to ~$macro kcal (${(dev * 100).round()} % off). '
          'Check these numbers against the pack.',
        );
      }
    }

    final p = _per100;
    final s = _serving;
    check('Per 100 $_unit', p);
    check('Per serving', s);
    final size = _d(_size);
    if (p.kcal != null && s.kcal != null && size != null && size > 0) {
      final expected = p.kcal! * size / 100;
      if (expected > 0 && (s.kcal! - expected).abs() / expected > 0.15) {
        out.add(
          'Per-serving energy (${s.kcal!.round()} kcal) does not match '
          '${plainNum(size)} $_unit of the per 100 $_unit column '
          '(~${expected.round()} kcal). Check the serving size.',
        );
      }
    }
    return out;
  }

  FoodCandidate? get _candidate {
    final c = labelToCandidate(
      name: _name.text,
      brand: _brand.text,
      barcode: _barcode.text,
      per100: _per100,
      serving: _serving,
      servingSize: _d(_size),
      unit: _unit,
    );
    return c.toBasis() == null ? null : c;
  }

  List<String> _editedFields() {
    final r = _reading;
    if (r == null) return const [];
    final out = <String>[];
    void cmp(String prefix, LabelColumn before, LabelColumn after) {
      final pairs = {
        'kcal': (before.kcal, after.kcal),
        'protein_g': (before.protein, after.protein),
        'carbs_g': (before.carbs, after.carbs),
        'fat_g': (before.fat, after.fat),
        'fiber_g': (before.fiber, after.fiber),
        'sugar_g': (before.sugar, after.sugar),
      };
      pairs.forEach((k, v) {
        if (v.$1 != v.$2) out.add('$prefix.$k');
      });
    }

    cmp('per_100g', r.per100, _per100);
    cmp('serving', r.serving, _serving);
    if (r.servingSize != _d(_size)) out.add(LabelFields.servingSize);
    if ((r.productName ?? '') != _name.text.trim()) out.add('product_name');
    return out;
  }

  Map<String, Object?> _colJson(LabelColumn c) => {
    'kcal': ?c.kcal,
    'protein_g': ?c.protein,
    'carbs_g': ?c.carbs,
    'fat_g': ?c.fat,
    'fiber_g': ?c.fiber,
    'sugar_g': ?c.sugar,
  };

  Future<void> _save({required bool logNow}) async {
    setState(() {
      _submitted = true;
      _errors = _validate();
    });
    final cand = _candidate;
    if (_errors.isNotEmpty || cand == null) {
      Haptics.warning();
      return;
    }
    final basis = cand.toBasis()!;
    final per100 = _per100;
    final serving = _serving;
    final raw = <String, Object?>{
      'provider': 'nutrition_label_photo',
      'read_by': 'ai',
      'ai_provider': ?_provider,
      'confirmed_by_user': true,
      'edited_fields': _editedFields(),
      'label': {
        'unit': _unit,
        'serving_size': ?_d(_size),
        'per_100': _colJson(per100),
        'per_serving': _colJson(serving),
      },
      if (per100.energyFromKj || serving.energyFromKj)
        'energy_kcal_derived_from_kj': true,
      'ai_extraction': ?_reading?.raw,
    };
    final draft = FoodDraft(
      name: _name.text,
      brand: _brand.text,
      barcode: _barcode.text,
      basis: basis,
      source: FoodSources.custom,
      // Typed by the AI from the label, then checked and confirmed by the
      // user: the same trust level as values typed in by hand.
      verification: Verifications.userEntered,
      rawJson: jsonEncode(raw),
    );
    setState(() => _saving = true);
    try {
      final food = await ref.read(foodRepositoryProvider).create(draft);
      Haptics.success();
      if (!mounted) return;
      var logged = false;
      if (logNow) {
        logged = await logLocalFood(
          context,
          ref,
          food: food,
          meal: _meal,
          date: _date,
        );
      } else {
        showSnack(context, 'Saved "${food.name}" to My foods');
      }
      if (mounted) {
        Navigator.of(context).pop(LabelScanOutcome(food, logged: logged));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(context, 'Could not save: ${redactSecrets(e.toString())}');
      }
    }
  }

  void _zoom() {
    final photo = _photo;
    if (photo == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(AppSpacing.md),
        clipBehavior: Clip.antiAlias,
        child: InteractiveViewer(
          maxScale: 5,
          child: Image.memory(photo, fit: BoxFit.contain),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _stage == _Stage.review
              ? 'Check label values'
              : 'Scan nutrition label',
        ),
        actions: [
          if (_stage == _Stage.review)
            TextButton.icon(
              onPressed: _saving
                  ? null
                  : () => setState(() {
                      _stage = _Stage.capture;
                      _message = null;
                    }),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retake'),
            ),
        ],
      ),
      body: _stage == _Stage.review ? _review(context) : _capture(context),
    );
  }

  Widget _capture(BuildContext context) {
    final consent = ref.watch(aiPhotoConsentProvider).value ?? false;
    final reader = ref.watch(nutritionLabelReaderProvider);
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final reading = _stage == _Stage.reading;
    final ready = consent && reader.isConfigured && !reading;
    final name = _name.text.trim();
    final code = _barcode.text.trim();
    return ListView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.sm,
        AppSpacing.gutter,
        MediaQuery.paddingOf(context).bottom + AppSpacing.xxxl,
      ),
      children: [
        Text(
          'Photograph the nutrition table on the pack. JARVIS copies the '
          'printed values (it never guesses); you check every number before '
          'it is saved to My foods.',
          style: t.bodyMedium?.copyWith(color: hud.textMuted),
        ),
        if (name.isNotEmpty || code.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              if (name.isNotEmpty)
                HudChip(
                  label: name,
                  icon: Icons.inventory_2_outlined,
                  uppercase: false,
                ),
              if (code.isNotEmpty)
                HudChip(
                  label: code,
                  icon: Icons.qr_code_2_rounded,
                  uppercase: false,
                ),
            ],
          ),
        ],
        if (!reader.isConfigured) ...[
          const SizedBox(height: AppSpacing.lg),
          const NoticeBanner(
            icon: Icons.cloud_off_outlined,
            color: AppColors.warning,
            message: labelReaderNotConfiguredMessage,
          ),
        ] else if (!consent) ...[
          const SizedBox(height: AppSpacing.lg),
          _ConsentCard(consent: consent, onChanged: _setConsent),
        ],
        const SizedBox(height: AppSpacing.lg),
        HudFrame(
          tag: 'LABEL · AI READ',
          ticks: true,
          color: (ready || _photo != null ? hud.accent : hud.textMuted)
              .withValues(alpha: 0.8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.md),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_photo != null && reading)
                    Image.memory(_photo!, fit: BoxFit.cover)
                  else
                    ColoredBox(
                      color: hud.text.withValues(alpha: 0.03),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.xl),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              GlowIcon(
                                Icons.document_scanner_outlined,
                                size: 30,
                                color: ready ? hud.accent : hud.textMuted,
                                framed: true,
                              ),
                              const SizedBox(height: AppSpacing.md),
                              Text(
                                ready
                                    ? 'Fill the frame with the "Nutrition '
                                          'Information" table. Flat, sharp, '
                                          'no glare.'
                                    : !reader.isConfigured
                                    ? 'AI label reading isn\'t available. '
                                          'Type the values instead.'
                                    : 'Allow photo sending above to scan.',
                                textAlign: TextAlign.center,
                                style: t.bodyMedium?.copyWith(
                                  color: hud.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (reading) ...[
                    ColoredBox(color: Colors.black.withValues(alpha: 0.25)),
                    const ScanSweep(),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Text(
                          'READING LABEL…',
                          style: hud.mono(size: 11, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (reader.isConfigured)
          Row(
            children: [
              Expanded(
                child: KeyedSubtree(
                  key: const Key('label-take-photo'),
                  child: HudButton(
                    label: 'Take photo',
                    icon: Icons.photo_camera_outlined,
                    expand: true,
                    loading: reading,
                    onPressed: ready ? () => _pick(ImageSource.camera) : null,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: HudButton.secondary(
                  label: 'Gallery',
                  icon: Icons.photo_library_outlined,
                  expand: true,
                  onPressed: ready ? () => _pick(ImageSource.gallery) : null,
                ),
              ),
            ],
          ),
        if (_message != null) ...[
          const SizedBox(height: AppSpacing.lg),
          NoticeBanner(message: _message!, color: AppColors.warning),
        ],
        const SizedBox(height: AppSpacing.md),
        KeyedSubtree(
          key: const Key('label-manual'),
          child: reader.isConfigured
              ? HudButton.ghost(
                  label: 'Type label values instead',
                  icon: Icons.edit_note_rounded,
                  expand: true,
                  onPressed: reading ? null : _manual,
                )
              : HudButton(
                  label: 'Type label values',
                  icon: Icons.edit_note_rounded,
                  expand: true,
                  onPressed: _manual,
                ),
        ),
      ],
    );
  }

  Widget _review(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final r = _reading!;
    final flagged = _flagged;
    final warnings = _warnings;
    final cand = _candidate;
    final basis = cand?.toBasis();
    final unreadable = r.unreadableFields;
    final conf = r.confidence;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Column(
      children: [
        // Photo stays in view while the values are checked.
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.xs,
            AppSpacing.gutter,
            AppSpacing.sm,
          ),
          child: GlassPanel(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  button: true,
                  label: 'Zoom label photo',
                  child: PressableScale(
                    onTap: _zoom,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      child: SizedBox(
                        width: 84,
                        height: 108,
                        child: _photo == null
                            ? ColoredBox(
                                color: hud.text.withValues(alpha: 0.05),
                              )
                            : Image.memory(_photo!, fit: BoxFit.cover),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('READ FROM LABEL', style: hud.label(size: 10)),
                      const SizedBox(height: 4),
                      Text(
                        _name.text.trim().isEmpty
                            ? 'Unnamed product'
                            : _name.text.trim(),
                        style: t.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Wrap(
                        spacing: AppSpacing.xs,
                        runSpacing: AppSpacing.xs,
                        children: [
                          if (conf != null)
                            HudChip(
                              label: 'Legibility ${(conf * 100).round()}%',
                              color: conf >= 0.7
                                  ? AppColors.success
                                  : AppColors.warning,
                              selected: true,
                            ),
                          if (flagged.isNotEmpty)
                            HudChip(
                              label: '${flagged.length} to check',
                              icon: Icons.flag_outlined,
                              color: AppColors.warning,
                              selected: true,
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        'Tap the photo to zoom. Compare every value.',
                        style: t.bodySmall?.copyWith(color: hud.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.xs,
              AppSpacing.gutter,
              bottom + AppSpacing.xxxl,
            ),
            children: [
              if (unreadable.isNotEmpty) ...[
                NoticeBanner(
                  icon: Icons.flag_outlined,
                  color: AppColors.warning,
                  message:
                      'Couldn\'t read: '
                      '${unreadable.map((u) => LabelFields.human(u, unit: _unit)).join(', ')}. '
                      'Type these from the pack (left empty, never guessed).',
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              if (r.energyFromKj) ...[
                const NoticeBanner(
                  icon: Icons.swap_horiz_rounded,
                  message:
                      'The label shows energy only in kJ. Calories were '
                      'converted (kJ ÷ 4.184).',
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              for (final w in warnings) ...[
                NoticeBanner(
                  icon: Icons.calculate_outlined,
                  color: AppColors.warning,
                  message: w,
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              if (_errors['basis'] != null) ...[
                NoticeBanner(
                  icon: Icons.error_outline_rounded,
                  color: AppColors.danger,
                  message: _errors['basis']!,
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              const SizedBox(height: AppSpacing.xs),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const HudCaption('Product'),
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      key: const Key('label-name'),
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: 'Name *',
                        errorText: _errors['name'],
                      ),
                      onChanged: (_) => _changed(),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      key: const Key('label-brand'),
                      controller: _brand,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Brand'),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      key: const Key('label-barcode'),
                      controller: _barcode,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: 'Barcode (optional)',
                        prefixIcon: const Icon(Icons.qr_code_2_rounded),
                        helperText: 'Scanning it later finds this food offline',
                        errorText: _errors['barcode'],
                      ),
                      onChanged: (_) => _changed(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _columnCard(
                context,
                title: 'Per 100 $_unit',
                prefix: 'per_100g',
                ctrls: _p100,
                flagged: flagged,
                trailing: SizedBox(
                  width: 112,
                  child: SegmentedHud<String>(
                    value: _unit,
                    segments: const [
                      HudSegment(value: 'g', label: 'g'),
                      HudSegment(value: 'ml', label: 'ml'),
                    ],
                    onChanged: (u) => setState(() => _unit = u),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _columnCard(
                context,
                title: 'Per serving',
                prefix: 'serving',
                ctrls: _serv,
                flagged: flagged,
                header: _numField(
                  LabelFields.servingSize,
                  _size,
                  'Serving size',
                  suffix: _unit,
                  flagged: flagged,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              AppCard(
                accent: AppColors.calories,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    HudCaption(
                      basis == null
                          ? 'Will be saved as'
                          : 'Will be saved per ${basis.servingLabel}',
                      color: AppColors.calories,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (basis == null)
                      Text(
                        'Fill energy, protein, carbs and fat in one column '
                        'to see the preview.',
                        style: t.bodySmall?.copyWith(color: hud.textMuted),
                      )
                    else ...[
                      NutrientPreview(nutrients: basis.perServing),
                      const SizedBox(height: AppSpacing.md),
                      MacroSplitBar(
                        protein: basis.perServing.protein,
                        carbs: basis.perServing.carbs,
                        fat: basis.perServing.fat,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        basis.supportsGrams
                            ? 'Log it by servings or by ${basis.baseUnit}.'
                            : 'Add a serving size to log it by '
                                  '${_unit == 'ml' ? 'ml' : 'grams'} too.',
                        style: t.bodySmall?.copyWith(color: hud.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Saved as "Entered by you": the AI read the label and you '
                'confirmed the values.',
                style: t.bodySmall?.copyWith(color: hud.textMuted),
              ),
              const SizedBox(height: AppSpacing.lg),
              KeyedSubtree(
                key: const Key('label-save-log'),
                child: HudButton(
                  label: 'Save & log to ${_meal.label}',
                  icon: Icons.playlist_add_check_rounded,
                  expand: true,
                  loading: _saving,
                  onPressed: _saving ? null : () => _save(logNow: true),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              KeyedSubtree(
                key: const Key('label-save'),
                child: HudButton.secondary(
                  label: 'Save to My foods',
                  icon: Icons.inventory_2_outlined,
                  expand: true,
                  onPressed: _saving ? null : () => _save(logNow: false),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _changed() {
    setState(() {
      if (_submitted) _errors = _validate();
    });
  }

  Widget _columnCard(
    BuildContext context, {
    required String title,
    required String prefix,
    required Map<String, TextEditingController> ctrls,
    required Set<String> flagged,
    Widget? trailing,
    Widget? header,
  }) {
    Widget f(String key, {String suffix = 'g'}) => _numField(
      '$prefix.$key',
      ctrls[key]!,
      LabelFields.label(key),
      suffix: suffix,
      flagged: flagged,
    );
    Widget row(Widget a, Widget b) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: a),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: b),
      ],
    );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: HudCaption(title)),
              ?trailing,
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (header != null) ...[
            header,
            const SizedBox(height: AppSpacing.md),
          ],
          row(f('kcal', suffix: 'kcal'), f('protein_g')),
          const SizedBox(height: AppSpacing.md),
          row(f('carbs_g'), f('fat_g')),
          const SizedBox(height: AppSpacing.md),
          row(f('fiber_g'), f('sugar_g')),
        ],
      ),
    );
  }

  Widget _numField(
    String id,
    TextEditingController c,
    String label, {
    required String suffix,
    required Set<String> flagged,
  }) {
    final flag = flagged.contains(id);
    return TextField(
      key: Key('label-$id'),
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        errorText: _errors[id],
        helperText: flag ? 'Check on pack' : null,
        helperStyle: flag
            ? TextStyle(color: context.hud.ink(AppColors.warning))
            : null,
        prefixIcon: flag
            ? const Icon(
                Icons.flag_outlined,
                size: 18,
                color: AppColors.warning,
              )
            : null,
        prefixIconConstraints: const BoxConstraints(minWidth: 36),
      ),
      onChanged: (_) => _changed(),
    );
  }
}

class _ConsentCard extends StatelessWidget {
  const _ConsentCard({required this.consent, required this.onChanged});
  final bool consent;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    return AppCard(
      accent: AppColors.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.privacy_tip_outlined,
                size: 18,
                color: AppColors.warning,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text('Before you use this', style: t.titleMedium),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'The label photo is sent to a third-party AI provider (configured '
            'by you) to read the values. This uses the same permission as '
            'meal photos. Photos are not stored by Athlete OS.',
            style: t.bodyMedium?.copyWith(color: hud.textMuted),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: Text(
                  'I agree to send photos to the AI provider',
                  style: t.titleSmall,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              HudToggle(
                key: const Key('label-photo-consent'),
                value: consent,
                color: AppColors.warning,
                semanticLabel: 'I agree to send photos to the AI provider',
                onChanged: onChanged,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Opens the label scanner and returns what it saved (if anything).
Future<LabelScanOutcome?> openLabelScan(
  BuildContext context, {
  String? name,
  String? barcode,
  MealType? meal,
  String? date,
}) => Navigator.of(context).push<LabelScanOutcome>(
  MaterialPageRoute(
    builder: (_) => LabelScanScreen(
      initialName: name,
      barcode: barcode,
      meal: meal,
      date: date,
    ),
  ),
);
