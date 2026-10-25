import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/util/format.dart';
import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/settings_repository.dart';
import '../application/providers.dart';
import '../data/food_log_repository.dart';
import '../domain/ai_contracts.dart';
import '../domain/food_models.dart';
import '../domain/nutrients.dart';
import 'widgets/common.dart';
import 'widgets/nutrition_hud.dart';
import 'widgets/scan_sweep.dart';

/// Meal photo → AI estimate. Gated behind explicit consent (default off);
/// results are estimates that must be confirmed item by item.
class MealPhotoScreen extends ConsumerStatefulWidget {
  const MealPhotoScreen({super.key, required this.meal, required this.date});
  final MealType meal;
  final String date;

  @override
  ConsumerState<MealPhotoScreen> createState() => _MealPhotoScreenState();
}

class _MealPhotoScreenState extends ConsumerState<MealPhotoScreen> {
  Uint8List? _image;
  bool _busy = false;
  String? _message;
  List<(EstimatedFood, bool)> _items = const [];

  Future<void> _setConsent(bool v) =>
      ref.read(settingsRepositoryProvider).set(SettingKeys.aiPhotoConsent, v);

  Future<void> _pick(ImageSource source) async {
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        // Keeps the JPEG well under the backend's 1 MB image limit.
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 80,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        _image = bytes;
        _busy = true;
        _message = null;
        _items = const [];
      });
      final result = await ref
          .read(mealPhotoAnalyzerProvider)
          .analyze(bytes, mimeType: file.mimeType ?? 'image/jpeg');
      if (!mounted) return;
      setState(() {
        _busy = false;
        switch (result) {
          case FoodEstimateUnavailable(:final reason):
            _message = reason;
          case FoodEstimateFailure(:final message):
            _message = redactSecrets(message);
          case FoodEstimateSuccess(:final items):
            _items = [for (final i in items) (i, false)];
            if (items.isEmpty) _message = 'No foods were recognised.';
        }
      });
      if (_items.isEmpty) {
        Haptics.warning();
      } else {
        Haptics.success();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = 'Could not get a photo: ${redactSecrets(e.toString())}';
        });
      }
    }
  }

  Future<void> _logConfirmed() async {
    final log = ref.read(foodLogRepositoryProvider);
    var n = 0;
    for (final (item, ok) in _items) {
      if (!ok) continue;
      await log.log(
        LogDraft(
          name: item.name,
          mealType: widget.meal,
          nutrients: item.nutrients,
          grams: item.grams,
          source: FoodSources.aiEstimate,
          verification: Verifications.estimate,
          note: 'From meal photo (AI estimate)',
        ),
        localDate: widget.date,
      );
      n++;
    }
    if (!mounted) return;
    Haptics.success();
    showSnack(context, 'Logged $n estimated item${n == 1 ? '' : 's'}');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final consent = ref.watch(aiPhotoConsentProvider).value ?? false;
    final analyzer = ref.watch(mealPhotoAnalyzerProvider);
    final t = Theme.of(context).textTheme;
    final hud = context.hud;
    final confirmed = _items.where((i) => i.$2).length;
    final ready = consent && analyzer.isConfigured && !_busy;
    var total = Nutrients.zero;
    for (final (item, ok) in _items) {
      if (ok) total = total + item.nutrients;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Meal photo')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.sm,
          AppSpacing.gutter,
          MediaQuery.paddingOf(context).bottom + AppSpacing.xxxl,
        ),
        children: [
          AppCard(
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
                  'Meal photos are sent to a third-party AI provider '
                  '(configured by you) to estimate foods and portions. '
                  'Results are estimates, often off by 20–50%, and are only '
                  'saved after you confirm each item. Photos are not stored '
                  'by Athlete OS.',
                  style: t.bodyMedium?.copyWith(color: hud.textMuted),
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'I agree to send meal photos to the AI provider',
                        style: t.titleSmall,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    HudToggle(
                      key: const Key('photo-consent'),
                      value: consent,
                      color: AppColors.warning,
                      semanticLabel:
                          'I agree to send meal photos to the AI provider',
                      onChanged: _setConsent,
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (!analyzer.isConfigured) ...[
            const SizedBox(height: AppSpacing.md),
            const NoticeBanner(
              icon: Icons.cloud_off_outlined,
              color: AppColors.warning,
              message: photoNotConfiguredMessage,
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          HudFrame(
            tag: 'CAM · AI EST',
            ticks: true,
            color: (ready || _image != null ? hud.accent : hud.textMuted)
                .withValues(alpha: 0.8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.md),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_image != null)
                      Image.memory(_image!, fit: BoxFit.cover)
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
                                  Icons.photo_camera_outlined,
                                  size: 30,
                                  color: ready ? hud.accent : hud.textMuted,
                                  framed: true,
                                ),
                                const SizedBox(height: AppSpacing.md),
                                Text(
                                  ready
                                      ? 'Shoot from above with the whole '
                                            'plate in frame.'
                                      : consent
                                      ? 'AI photo analysis isn\'t set up yet.'
                                      : 'Turn on consent above to use '
                                            'photos.',
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
                    if (_busy) ...[
                      ColoredBox(color: Colors.black.withValues(alpha: 0.25)),
                      const ScanSweep(),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          child: Text(
                            'ANALYSING PLATE…',
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
          Row(
            children: [
              Expanded(
                child: HudButton(
                  label: 'Take photo',
                  icon: Icons.photo_camera_outlined,
                  expand: true,
                  onPressed: ready ? () => _pick(ImageSource.camera) : null,
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
          if (_items.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            const HudCaption(
              'AI estimates · confirm each',
              color: AppColors.warning,
              trailing: EstimateBadge(),
            ),
            const SizedBox(height: AppSpacing.sm),
            ...staggered([
              for (var i = 0; i < _items.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: AppCard(
                    accent: AppColors.warning,
                    onTap: () => _toggle(i, !_items[i].$2),
                    semanticLabel:
                        '${_items[i].$1.name}, estimate. '
                        '${_items[i].$2 ? 'Confirmed' : 'Not confirmed'}',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _items[i].$1.name,
                                style: t.titleSmall,
                              ),
                            ),
                            HudToggle(
                              value: _items[i].$2,
                              color: AppColors.warning,
                              semanticLabel: 'Confirm ${_items[i].$1.name}',
                              onChanged: (v) => _toggle(i, v),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        NutrientPreview(
                          nutrients: _items[i].$1.nutrients,
                          estimate: true,
                        ),
                      ],
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: AppSpacing.md),
            Text(
              confirmed == 0
                  ? 'Nothing confirmed yet'
                  : 'Confirmed: ${Fmt.kcal(total.calories)} · '
                        'P ${Fmt.grams(total.protein)} (estimate)',
              style: hud.mono(size: 11),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.md),
            HudButton(
              label: 'Log $confirmed confirmed estimate(s)',
              icon: Icons.check_rounded,
              expand: true,
              onPressed: confirmed == 0 ? null : _logConfirmed,
            ),
          ],
        ],
      ),
    );
  }

  void _toggle(int i, bool v) => setState(() {
    final list = [..._items];
    list[i] = (list[i].$1, v);
    _items = list;
  });
}
