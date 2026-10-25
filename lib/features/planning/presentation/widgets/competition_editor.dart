import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../data/db/database.dart';
import '../../application/planning_providers.dart';
import '../../data/planning_repository.dart';
import '../../domain/countdown.dart';
import 'ui_helpers.dart';

/// Opens the create/edit competition sheet.
Future<void> showCompetitionEditor(
  BuildContext context, {
  Competition? existing,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => CompetitionEditor(existing: existing),
);

class CompetitionEditor extends ConsumerStatefulWidget {
  const CompetitionEditor({super.key, this.existing});
  final Competition? existing;

  @override
  ConsumerState<CompetitionEditor> createState() => _CompetitionEditorState();
}

class _CompetitionEditorState extends ConsumerState<CompetitionEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _location = TextEditingController(text: widget.existing?.location);
  late final _division = TextEditingController(text: widget.existing?.division);
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late String? _date = widget.existing?.eventDate;
  String? _tz;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tz = widget.existing?.tzName;
  }

  @override
  void dispose() {
    _name.dispose();
    _location.dispose();
    _division.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save(String fallbackTz) async {
    if (!_form.currentState!.validate()) return;
    if (_date == null) {
      showSnack(context, 'Choose the event date.');
      return;
    }
    setState(() => _saving = true);
    await ref
        .read(planningRepositoryProvider)
        .saveCompetition(
          id: widget.existing?.id,
          name: _name.text,
          eventDate: _date!,
          tzName: _tz ?? fallbackTz,
          location: _location.text,
          division: _division.text,
          notes: _notes.text,
        );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final device = ref.watch(deviceTimeZoneProvider).value;
    final fallback = device ?? 'UTC';
    final zones = <String>{?device, ...commonTimeZones, ?_tz}.toList();
    final selected = _tz ?? fallback;
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.gutter,
        right: AppSpacing.gutter,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpacing.xl,
      ),
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.existing == null
                    ? 'Set competition'
                    : 'Edit competition',
                style: t.titleLarge,
              ),
              const SizedBox(height: AppSpacing.lg),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Competition name',
                  hintText: 'e.g. State Classic Physique',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
              ),
              const SizedBox(height: AppSpacing.md),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.event),
                label: Text(
                  _date == null ? 'Choose event date' : formatDateKey(_date!),
                ),
                onPressed: () async {
                  final d = await pickDateKey(
                    context,
                    initial: _date,
                    helpText: 'Event date',
                  );
                  if (d != null) setState(() => _date = d);
                },
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
                key: ValueKey('tz-$selected-${zones.length}'),
                initialValue: selected,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Event timezone',
                  helperText:
                      'The countdown uses the calendar date where the event '
                      'takes place.',
                ),
                items: [
                  for (final z in zones)
                    DropdownMenuItem(
                      value: z,
                      child: Text(z == device ? '$z (this device)' : z),
                    ),
                ],
                onChanged: (v) => setState(() => _tz = v),
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _location,
                decoration: const InputDecoration(labelText: 'Location'),
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _division,
                decoration: const InputDecoration(
                  labelText: 'Division / category',
                  hintText: "e.g. Men's Physique — Novice",
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _notes,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Notes'),
              ),
              const SizedBox(height: AppSpacing.xl),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                onPressed: _saving ? null : () => _save(fallback),
                child: const Text('Save'),
              ),
              if (widget.existing != null) ...[
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.danger,
                  ),
                  onPressed: () async {
                    final ok = await confirm(
                      context,
                      title: 'Remove competition?',
                      message:
                          'The countdown is removed. Milestones stay in the '
                          'database until you delete all data.',
                      confirmLabel: 'Remove',
                      destructive: true,
                    );
                    if (!ok || !context.mounted) return;
                    await ref
                        .read(planningRepositoryProvider)
                        .deleteCompetition(widget.existing!.id);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Remove competition'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
