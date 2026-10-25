import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../data/db/database.dart';
import '../data/coach_repository.dart';
import '../tools/tool_registry.dart';

final _toolActionsProvider = StreamProvider.autoDispose
    .family<List<AiToolAction>, bool>(
      (ref, writesOnly) => ref
          .watch(coachRepositoryProvider)
          .watchToolActions(writesOnly: writesOnly),
    );

/// One-line, human-readable summary of a stored tool result.
String summarizeToolResult(String? json) {
  if (json == null) return '';
  try {
    final m = jsonDecode(json);
    if (m is! Map) return '';
    if (m['error'] != null) {
      return 'Error: ${m['message'] ?? m['error']}';
    }
    if (m['status'] is String) {
      return '${m['status']}'.replaceAll('_', ' ');
    }
    final missing = m['missing'];
    if (missing is List && missing.isNotEmpty) {
      return 'Missing: ${missing.take(2).join('; ')}';
    }
    final prov = m['provenance'];
    if (prov is Map && prov['sources'] is List) {
      return 'Sources: ${(prov['sources'] as List).join(', ')}';
    }
  } catch (_) {}
  return '';
}

class AiHistoryScreen extends ConsumerStatefulWidget {
  const AiHistoryScreen({super.key});

  @override
  ConsumerState<AiHistoryScreen> createState() => _AiHistoryScreenState();
}

class _AiHistoryScreenState extends ConsumerState<AiHistoryScreen> {
  bool _writesOnly = false;

  Color _statusColor(String status) => switch (status) {
    'ok' || 'confirmed' => AppColors.success,
    'error' => AppColors.danger,
    'pending_confirmation' => AppColors.warning,
    _ => Theme.of(context).colorScheme.onSurfaceVariant,
  };

  Future<void> _editRecommendation(AiRecommendation r) async {
    final controller = TextEditingController(text: r.content);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit recommendation'),
        content: TextField(controller: controller, maxLines: 4, maxLength: 300),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    await ref
        .read(coachRepositoryProvider)
        .respondToRecommendation(r.id, 'edited', editedContent: text);
  }

  @override
  Widget build(BuildContext context) {
    final actions = ref.watch(_toolActionsProvider(_writesOnly));
    final recs = ref.watch(recommendationsProvider);
    final repo = ref.read(coachRepositoryProvider);
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();

    return AppPage(
      title: 'AI activity log',
      subtitle:
          'Every tool the coach used, what it read or changed, and your '
          'responses to its recommendations.',
      children: [
        const SectionHeader('Recommendations'),
        ...recs.when(
          loading: () => const [LoadingState()],
          error: (e, _) => const [
            ErrorState(message: 'Could not load recommendations.'),
          ],
          data: (list) => list.isEmpty
              ? const [
                  EmptyState(
                    icon: Icons.lightbulb_outline,
                    title: 'No saved recommendations yet',
                    compact: true,
                  ),
                ]
              : spaced([
                  for (final r in list.take(50))
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${r.kind} · ${Fmt.ago(r.createdAt, now)} · ${r.status}',
                            style: t.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(r.content, style: t.bodyMedium),
                          if (r.status == 'pending')
                            Wrap(
                              spacing: AppSpacing.sm,
                              children: [
                                TextButton(
                                  onPressed: () => repo.respondToRecommendation(
                                    r.id,
                                    'accepted',
                                  ),
                                  child: const Text('Accept'),
                                ),
                                TextButton(
                                  onPressed: () => _editRecommendation(r),
                                  child: const Text('Edit'),
                                ),
                                TextButton(
                                  onPressed: () => repo.respondToRecommendation(
                                    r.id,
                                    'dismissed',
                                  ),
                                  child: const Text('Dismiss'),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                ]),
        ),
        SectionHeader(
          'Tool activity',
          action: _writesOnly ? 'Show all' : 'Changes only',
          onAction: () => setState(() => _writesOnly = !_writesOnly),
        ),
        ...actions.when(
          loading: () => const [LoadingState()],
          error: (e, _) => const [
            ErrorState(message: 'Could not load activity.'),
          ],
          data: (list) => list.isEmpty
              ? const [
                  EmptyState(
                    icon: Icons.history,
                    title: 'No AI activity yet',
                    compact: true,
                  ),
                ]
              : [
                  AppCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (final a in list)
                          ListTile(
                            dense: true,
                            leading: Icon(
                              a.isWrite
                                  ? Icons.edit_note
                                  : Icons.dataset_outlined,
                              color: _statusColor(a.status),
                            ),
                            title: Text(_title(a, now)),
                            subtitle: Text(
                              [
                                a.status.replaceAll('_', ' '),
                                Fmt.ago(a.createdAt, now),
                                summarizeToolResult(a.resultSummary),
                              ].where((s) => s.isNotEmpty).join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
        ),
      ],
    );
  }

  String _title(AiToolAction a, DateTime now) {
    final spec = toolByName(a.toolName);
    if (spec == null) return a.toolName;
    try {
      final args = (jsonDecode(a.argsJson) as Map).cast<String, Object?>();
      return spec.chipLabel(args, a.createdAt.toLocal());
    } catch (_) {
      return a.toolName;
    }
  }
}
