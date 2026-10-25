import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/util/redact.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/repositories/settings_repository.dart';
import '../application/providers.dart';
import '../data/food_log_repository.dart';
import '../domain/ai_contracts.dart';
import '../domain/food_models.dart';
import 'widgets/common.dart';

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
    showSnack(context, 'Logged $n estimated item${n == 1 ? '' : 's'}');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final consent = ref.watch(aiPhotoConsentProvider).value ?? false;
    final analyzer = ref.watch(mealPhotoAnalyzerProvider);
    final t = Theme.of(context).textTheme;
    final confirmed = _items.where((i) => i.$2).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Meal photo')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        children: [
          AppCard(
            accent: AppColors.warning,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Before you use this', style: t.titleMedium),
                const SizedBox(height: AppSpacing.sm),
                const Text(
                  'Meal photos are sent to a third-party AI provider '
                  '(configured by you) to estimate foods and portions. '
                  'Results are estimates, often off by 20–50%, and are only '
                  'saved after you confirm each item. Photos are not stored '
                  'by Athlete OS.',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'I agree to send meal photos to the AI '
                    'provider',
                  ),
                  value: consent,
                  onChanged: _setConsent,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (!analyzer.isConfigured)
            const NoticeBanner(
              icon: Icons.cloud_off_outlined,
              color: AppColors.warning,
              message: photoNotConfiguredMessage,
            ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: consent && analyzer.isConfigured && !_busy
                      ? () => _pick(ImageSource.camera)
                      : null,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Take photo'),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: consent && analyzer.isConfigured && !_busy
                      ? () => _pick(ImageSource.gallery)
                      : null,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Gallery'),
                ),
              ),
            ],
          ),
          if (_image != null) ...[
            const SizedBox(height: AppSpacing.lg),
            ClipRRect(
              borderRadius: AppRadii.card,
              child: Image.memory(_image!, height: 220, fit: BoxFit.cover),
            ),
          ],
          if (_busy) const LoadingState(),
          if (_message != null) ...[
            const SizedBox(height: AppSpacing.lg),
            NoticeBanner(message: _message!, color: AppColors.warning),
          ],
          for (var i = 0; i < _items.length; i++)
            CheckboxListTile(
              value: _items[i].$2,
              onChanged: (v) => setState(() {
                final list = [..._items];
                list[i] = (list[i].$1, v ?? false);
                _items = list;
              }),
              title: Row(
                children: [
                  Flexible(child: Text(_items[i].$1.name)),
                  const SizedBox(width: AppSpacing.xs),
                  const EstimateBadge(),
                ],
              ),
              subtitle: Text(macroSummary(_items[i].$1.nutrients)),
            ),
          if (_items.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: confirmed == 0 ? null : _logConfirmed,
              child: Text('Log $confirmed confirmed estimate(s)'),
            ),
          ],
        ],
      ),
    );
  }
}
