import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/time/clock.dart';
import '../../../../core/util/ids.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../data/db/database.dart';
import '../../application/planning_providers.dart';
import '../../data/photo_storage.dart';
import '../../data/planning_repository.dart';
import 'ui_helpers.dart';

/// Private, on-device progress photos: add, browse by date, compare, delete.
class ProgressPhotosSection extends ConsumerStatefulWidget {
  const ProgressPhotosSection({super.key});

  @override
  ConsumerState<ProgressPhotosSection> createState() =>
      _ProgressPhotosSectionState();
}

class _ProgressPhotosSectionState extends ConsumerState<ProgressPhotosSection> {
  final _compare = <String>[];
  bool _comparing = false;
  bool _busy = false;

  Future<void> _add(ImageSource source) async {
    setState(() => _busy = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 2048,
        imageQuality: 90,
      );
      if (picked == null) return;
      final id = newId();
      final path = await ref.read(photoStorageProvider).import(picked.path, id);
      await ref
          .read(planningRepositoryProvider)
          .addPhotoRow(
            id: id,
            localPath: path,
            takenAt: ref.read(clockProvider).now(),
          );
    } catch (e) {
      if (mounted) showSnack(context, 'Could not add the photo.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(ProgressPhoto p) async {
    final ok = await confirm(
      context,
      title: 'Delete photo?',
      message: 'The image file and its record are permanently removed.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    await ref.read(photoStorageProvider).delete(p.localPath);
    await ref.read(planningRepositoryProvider).deletePhotoRow(p.id);
    _compare.remove(p.id);
    if (mounted) setState(() {});
  }

  void _tap(ProgressPhoto p, List<ProgressPhoto> all) {
    if (_comparing) {
      setState(() {
        if (_compare.contains(p.id)) {
          _compare.remove(p.id);
        } else if (_compare.length < 2) {
          _compare.add(p.id);
        }
      });
      if (_compare.length == 2) {
        final a = all.firstWhere((x) => x.id == _compare[0]);
        final b = all.firstWhere((x) => x.id == _compare[1]);
        final ordered = a.takenAt.isBefore(b.takenAt) ? [a, b] : [b, a];
        showDialog<void>(
          context: context,
          builder: (_) => _CompareDialog(photos: ordered),
        ).then((_) {
          if (mounted) {
            setState(() {
              _compare.clear();
              _comparing = false;
            });
          }
        });
      }
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: _PhotoImage(path: p.localPath, fit: BoxFit.contain),
            ),
            ListTile(
              title: Text(formatDateKey(p.localDate)),
              subtitle: const Text('Stored only on this device'),
              trailing: IconButton(
                tooltip: 'Delete photo',
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  Navigator.pop(ctx);
                  _delete(p);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final photos = ref.watch(progressPhotosProvider);
    final t = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CardTitle(
            icon: Icons.photo_library_outlined,
            title: 'Progress photos',
            color: AppColors.gold,
            trailing: (photos.value?.length ?? 0) >= 2
                ? TextButton(
                    onPressed: () => setState(() {
                      _comparing = !_comparing;
                      _compare.clear();
                    }),
                    child: Text(_comparing ? 'Cancel' : 'Compare'),
                  )
                : null,
          ),
          const SizedBox(height: AppSpacing.xs),
          const Row(
            children: [
              Icon(Icons.lock_outline, size: 14, color: AppColors.success),
              SizedBox(width: 6),
              Expanded(
                child: Hint(
                  'Private: stored only in app storage on this device, never '
                  'uploaded. AI photo analysis is not available.',
                ),
              ),
            ],
          ),
          if (_comparing)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text(
                'Select two photos to compare (${_compare.length}/2).',
                style: t.labelMedium?.copyWith(color: AppColors.gold),
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          photos.when(
            loading: () => const LoadingState(),
            error: (e, _) => const Hint('Could not load photos.'),
            data: (list) => list.isEmpty ? const _PoseSlots() : _grid(list),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: HudButton.secondary(
                  label: 'Take photo',
                  icon: Icons.photo_camera_outlined,
                  compact: true,
                  loading: _busy,
                  onPressed: _busy ? null : () => _add(ImageSource.camera),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: HudButton.ghost(
                  label: 'From gallery',
                  icon: Icons.photo_outlined,
                  compact: true,
                  onPressed: _busy ? null : () => _add(ImageSource.gallery),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _grid(List<ProgressPhoto> list) {
    final byDate = <String, List<ProgressPhoto>>{};
    for (final p in list) {
      byDate.putIfAbsent(p.localDate, () => []).add(p);
    }
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in byDate.entries) ...[
          Text(formatDateKey(entry.key), style: t.labelMedium),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final p in entry.value)
                Semantics(
                  button: true,
                  selected: _compare.contains(p.id),
                  label: 'Progress photo from ${formatDateKey(p.localDate)}',
                  child: PressableScale(
                    onTap: () => _tap(p, list),
                    haptic: _comparing
                        ? PressHaptic.selection
                        : PressHaptic.light,
                    child: Container(
                      width: 96,
                      height: 128,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(AppRadii.sm),
                        border: Border.all(
                          width: 2,
                          color: _compare.contains(p.id)
                              ? AppColors.gold
                              : context.hud.hairline.withValues(alpha: 0.2),
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _PhotoImage(path: p.localPath, cacheWidth: 300),
                          const Positioned(
                            right: 4,
                            top: 4,
                            child: _LockBadge(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ],
    );
  }
}

class _PhotoImage extends StatelessWidget {
  const _PhotoImage({
    required this.path,
    this.fit = BoxFit.cover,
    this.cacheWidth,
  });
  final String path;
  final BoxFit fit;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) => Image.file(
    File(path),
    fit: fit,
    cacheWidth: cacheWidth,
    errorBuilder: (_, _, _) => const ColoredBox(
      color: Colors.black26,
      child: Center(child: Icon(Icons.broken_image_outlined)),
    ),
  );
}

class _CompareDialog extends StatelessWidget {
  const _CompareDialog({required this.photos});
  final List<ProgressPhoto> photos;

  @override
  Widget build(BuildContext context) {
    final days = photos[1].takenAt.difference(photos[0].takenAt).inDays;
    return Dialog(
      insetPadding: const EdgeInsets.all(AppSpacing.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Compare · $days days apart',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.6,
              child: Row(
                children: [
                  for (final p in photos)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Column(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  AppRadii.sm,
                                ),
                                child: _PhotoImage(
                                  path: p.localPath,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              formatDateKey(p.localDate, pattern: 'd MMM yyyy'),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small "on-device only" badge over each photo.
class _LockBadge extends StatelessWidget {
  const _LockBadge();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(6),
    ),
    child: const Icon(Icons.lock, size: 11, color: Colors.white),
  );
}

/// Empty state: the three standard poses to capture, as outlined slots.
class _PoseSlots extends StatelessWidget {
  const _PoseSlots();

  @override
  Widget build(BuildContext context) {
    final hud = context.hud;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (final (i, pose) in const [
              'FRONT',
              'SIDE',
              'BACK',
            ].indexed) ...[
              if (i > 0) const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: HudFrame(
                    color: AppColors.gold.withValues(alpha: 0.6),
                    cornerLength: 10,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.gold.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(AppRadii.sm),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.accessibility_new,
                            size: 30,
                            color: hud.textMuted.withValues(alpha: 0.6),
                          ),
                          const SizedBox(height: 6),
                          Text(pose, style: hud.label(size: 10)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        const Hint(
          'No progress photos yet. Same light, same time of day, every '
          'two weeks.',
        ),
      ],
    );
  }
}
