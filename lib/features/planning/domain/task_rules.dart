/// Pure rules for daily priorities: ordering and explicit carryover.
library;

/// Storage-independent view of a task.
class TaskItem {
  const TaskItem({
    required this.id,
    required this.title,
    required this.localDate,
    this.priority = 2,
    this.done = false,
    this.carriedFromDate,
    this.project,
    this.deleted = false,
    this.createdAt,
  });

  final String id;
  final String title;
  final String localDate;
  final int priority;
  final bool done;
  final String? carriedFromDate;
  final String? project;
  final bool deleted;
  final DateTime? createdAt;
}

/// Undone, non-deleted tasks from [previousDate] that the user may explicitly
/// choose to carry over to the next day. Nothing is moved automatically.
List<TaskItem> carryoverCandidates(
  Iterable<TaskItem> tasks, {
  required String previousDate,
}) {
  final out = tasks
      .where((t) => t.localDate == previousDate && !t.done && !t.deleted)
      .toList();
  out.sort(compareByPriority);
  return out;
}

int compareByPriority(TaskItem a, TaskItem b) {
  final p = a.priority.compareTo(b.priority);
  if (p != 0) return p;
  final ca = a.createdAt, cb = b.createdAt;
  if (ca != null && cb != null) {
    final c = ca.compareTo(cb);
    if (c != 0) return c;
  }
  return a.id.compareTo(b.id);
}

/// Orders tasks by a user-defined manual order (ids), falling back to
/// priority for tasks not in [manualOrder].
List<TaskItem> orderTasks(Iterable<TaskItem> tasks, List<String> manualOrder) {
  final index = {
    for (var i = 0; i < manualOrder.length; i++) manualOrder[i]: i,
  };
  final list = tasks.where((t) => !t.deleted).toList();
  list.sort((a, b) {
    final ia = index[a.id], ib = index[b.id];
    if (ia != null && ib != null) return ia.compareTo(ib);
    if (ia != null) return -1;
    if (ib != null) return 1;
    return compareByPriority(a, b);
  });
  return list;
}

/// Top [n] priorities for the Today card: undone tasks first (in order),
/// then completed ones so progress stays visible.
List<TaskItem> topPriorities(
  Iterable<TaskItem> tasks,
  List<String> manualOrder, {
  int n = 3,
}) {
  final ordered = orderTasks(tasks, manualOrder);
  final undone = ordered.where((t) => !t.done);
  final done = ordered.where((t) => t.done);
  return [...undone, ...done].take(n).toList();
}
