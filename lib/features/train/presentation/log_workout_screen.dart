import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/time/clock.dart';
import '../../../core/util/format.dart';
import '../../../core/widgets/widgets.dart';
import '../data/csv_import_service.dart';
import '../data/workout_repository.dart';
import '../domain/strength_models.dart';
import '../domain/workout_draft.dart';

class _SetRow {
  _SetRow({String weight = '', String reps = ''})
    : weight = TextEditingController(text: weight),
      reps = TextEditingController(text: reps);
  final TextEditingController weight;
  final TextEditingController reps;
  bool warmup = false;
  void dispose() {
    weight.dispose();
    reps.dispose();
  }
}

class _ExerciseRow {
  _ExerciseRow() : name = TextEditingController();
  final TextEditingController name;
  final List<_SetRow> sets = [_SetRow()];
  void dispose() {
    name.dispose();
    for (final s in sets) {
      s.dispose();
    }
  }
}

/// Manual strength workout logging (source `manual`).
class LogWorkoutScreen extends ConsumerStatefulWidget {
  const LogWorkoutScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const LogWorkoutScreen()));

  @override
  ConsumerState<LogWorkoutScreen> createState() => _LogWorkoutScreenState();
}

class _LogWorkoutScreenState extends ConsumerState<LogWorkoutScreen> {
  final _title = TextEditingController(text: 'Workout');
  final _notes = TextEditingController();
  final _exercises = <_ExerciseRow>[_ExerciseRow()];
  late DateTime _start;
  int _durationMin = 60;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _start = ref.read(clockProvider).now();
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    for (final e in _exercises) {
      e.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime(2015),
      lastDate: ref.read(clockProvider).now().add(const Duration(days: 1)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_start),
    );
    setState(() {
      _start = DateTime(
        d.year,
        d.month,
        d.day,
        t?.hour ?? _start.hour,
        t?.minute ?? _start.minute,
      );
    });
  }

  WorkoutDraft? _draft() {
    final exercises = <ExerciseDraft>[];
    for (final e in _exercises) {
      final name = e.name.text.trim();
      if (name.isEmpty) continue;
      final sets = <SetDraft>[];
      for (final s in e.sets) {
        final w = double.tryParse(s.weight.text.replaceAll(',', '.'));
        final r = int.tryParse(s.reps.text);
        if (w == null && r == null) continue;
        sets.add(
          SetDraft(
            type: s.warmup ? SetTypes.warmup : SetTypes.normal,
            weightKg: w,
            reps: r,
          ),
        );
      }
      exercises.add(ExerciseDraft(name: name, sets: sets));
    }
    if (exercises.isEmpty) return null;
    return WorkoutDraft(
      title: _title.text.trim().isEmpty ? 'Workout' : _title.text.trim(),
      startAt: _start,
      endAt: _start.add(Duration(minutes: _durationMin)),
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      exercises: exercises,
    );
  }

  Future<void> _save() async {
    final draft = _draft();
    if (draft == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one named exercise.')),
      );
      return;
    }
    setState(() => _saving = true);
    await ref.read(workoutRepositoryProvider).saveManual(draft);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Workout saved')));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final numFmt = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Log workout'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title'),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event),
                  label: Text(
                    '${Fmt.weekdayDayMonth(_start)} · ${Fmt.time(_start)}',
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              DropdownButton<int>(
                value: _durationMin,
                items: [
                  for (final m in [30, 45, 60, 75, 90, 120])
                    DropdownMenuItem(value: m, child: Text('$m min')),
                ],
                onChanged: (v) => setState(() => _durationMin = v ?? 60),
              ),
            ],
          ),
          for (var i = 0; i < _exercises.length; i++) ...[
            const SizedBox(height: AppSpacing.lg),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _exercises[i].name,
                          decoration: InputDecoration(
                            labelText: 'Exercise ${i + 1}',
                            hintText: 'e.g. Bench Press (Barbell)',
                          ),
                          textCapitalization: TextCapitalization.words,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Remove exercise',
                        onPressed: _exercises.length == 1
                            ? null
                            : () => setState(
                                () => _exercises.removeAt(i).dispose(),
                              ),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  for (var j = 0; j < _exercises[i].sets.length; j++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 28,
                            child: Text('${j + 1}', style: t.labelLarge),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _exercises[i].sets[j].weight,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: numFmt,
                              decoration: const InputDecoration(
                                labelText: 'kg',
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: TextField(
                              controller: _exercises[i].sets[j].reps,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: const InputDecoration(
                                labelText: 'reps',
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          FilterChip(
                            label: const Text('Warm-up'),
                            selected: _exercises[i].sets[j].warmup,
                            onSelected: (v) => setState(
                              () => _exercises[i].sets[j].warmup = v,
                            ),
                          ),
                        ],
                      ),
                    ),
                  TextButton.icon(
                    onPressed: () => setState(() {
                      final last = _exercises[i].sets.last;
                      _exercises[i].sets.add(
                        _SetRow(weight: last.weight.text, reps: last.reps.text),
                      );
                    }),
                    icon: const Icon(Icons.add),
                    label: const Text('Add set'),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            onPressed: () => setState(() => _exercises.add(_ExerciseRow())),
            icon: const Icon(Icons.add),
            label: const Text('Add exercise'),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _notes,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Notes (optional)'),
          ),
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }
}

/// Paste-CSV dialog for Hevy's official export (a file picker requires the
/// `file_picker` package, not yet in pubspec).
Future<void> showCsvImportDialog(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Import Hevy CSV'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'In Hevy: Profile → Settings → Export & Import Data → Export '
              'workouts. Open the CSV, copy everything and paste it here. '
              'Re-importing the same file never creates duplicates.',
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: controller,
              maxLines: 8,
              minLines: 4,
              decoration: const InputDecoration(
                hintText: 'title,start_time,end_time,…',
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('Import'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (result == null || result.trim().isEmpty) return;
  final summary = await ref.read(csvImportServiceProvider).importText(result);
  if (!context.mounted) return;
  final warn = summary.warnings.isEmpty
      ? ''
      : ' (${summary.warnings.length} row(s) skipped: ${summary.warnings.first})';
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Imported ${summary.imported} workouts$warn')),
  );
}
