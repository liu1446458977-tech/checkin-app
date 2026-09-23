/// 统计快照：一次性把统计需要的数据从库里取出来，之后全部在内存里算。
/// 今日页、总览页、设置页共用，避免「每天每条任务都查一次库」的 N×M 查询。
library;

import 'core_logic.dart';
import 'db.dart';
import 'models.dart';

// 连续达标 / 统计快照的回溯窗口 kStreakLookbackDays 定义在 core_logic.dart，
// 与 calcStreak 的循环上限绑定，避免两处口径不一致造成静默截断。

class StatsSnapshot {
  final List<Task> tasks; // 含已归档
  final Map<String, Set<int>> completions; // date -> {taskId}
  /// 窗口内「曾经打过卡」的任务（周期任务完成一次即达成，靠它判断）
  final Set<int> everDoneTaskIds;
  final Set<String> restDates; // 单日休息
  final Set<int> weeklyRestWeekdays; // 每周固定休息（1..7）
  final Set<String> noteDates; // 有睡前总结的日期
  final DateTime rangeStart;
  final DateTime rangeEnd;

  const StatsSnapshot({
    required this.tasks,
    required this.completions,
    required this.everDoneTaskIds,
    required this.restDates,
    required this.weeklyRestWeekdays,
    required this.noteDates,
    required this.rangeStart,
    required this.rangeEnd,
  });

  bool isRest(DateTime d) => isRestDay(d,
      restDates: restDates, weeklyRestWeekdays: weeklyRestWeekdays);

  DayStat statAt(DateTime d) => computeDayStat(
        d,
        allTasks: tasks,
        doneTaskIds: completions[dateKey(d)] ?? const <int>{},
        everDoneTaskIds: everDoneTaskIds,
        isRest: isRest(d),
      );

  /// 连续达标天数（休息日不断签）
  int streak(DateTime today) => calcStreak(statAt, today);

  /// 某周期的聚合统计
  PeriodStats statsOf(Period p, {DateTime? until}) => aggregatePeriod(
        p,
        statAt: statAt,
        noteDates: noteDates,
        until: until,
      );

  bool hasNote(DateTime d) => noteDates.contains(dateKey(d));
}

/// 加载统计快照。`from` 会自动向前扩到至少 400 天，保证连续达标能回溯。
Future<StatsSnapshot> loadStats({
  required DateTime from,
  required DateTime to,
}) async {
  final db = Db.instance;
  final end = todayOnly(to);
  final wantStart = todayOnly(from);
  final minStart = end.subtract(const Duration(days: kStreakLookbackDays));
  final start = wantStart.isBefore(minStart) ? wantStart : minStart;
  final s = dateKey(start);
  final e = dateKey(end);

  final results = await Future.wait<Object>([
    db.getTasks(includeArchived: true),
    db.completionsInRange(s, e),
    db.allRestDates(),
    db.weeklyRestWeekdays(),
    db.datesWithNotes(s, e),
  ]);

  final byTask = results[1] as Map<String, Set<int>>;
  // 窗口内「曾经打过卡」的任务集合：周期任务完成一次即达成，用它判断
  final everDone = <int>{
    for (final ids in byTask.values) ...ids,
  };

  return StatsSnapshot(
    tasks: results[0] as List<Task>,
    completions: byTask,
    everDoneTaskIds: everDone,
    restDates: results[2] as Set<String>,
    weeklyRestWeekdays: results[3] as Set<int>,
    noteDates: results[4] as Set<String>,
    rangeStart: start,
    rangeEnd: end,
  );
}

/// 某天各任务的完成明细（AI 提示词用）
class DayBreakdown {
  final List<String> done;
  final List<String> undone;
  const DayBreakdown({required this.done, required this.undone});
}

/// 与 computeDayStat 口径一致：任务在创建之前不出现、归档任务不计入待办，
/// 排期外/已归档但当天真打过卡的也算完成。
DayBreakdown dayBreakdown(StatsSnapshot snap, DateTime d) {
  final day = todayOnly(d);
  final key = dateKey(day);
  final doneIds = snap.completions[key] ?? const <int>{};
  final done = <String>[];
  final undone = <String>[];
  for (final t in snap.tasks) {
    if (todayOnly(t.createdAt).isAfter(day)) continue;
    final doneThatDay = doneIds.contains(t.id);
    if (!scheduledOn(t, day) || t.archived) {
      // 不在当天排期里（或已归档）却真打过卡的，只进「已完成」，不产生待办
      if (doneThatDay) done.add(t.name);
      continue;
    }
    final ok = t.repeatDaily
        ? doneThatDay
        : (t.endDate != null
            ? snap.everDoneTaskIds.contains(t.id)
            : doneThatDay);
    if (ok) {
      done.add(t.name);
    } else {
      undone.add(t.name);
    }
  }
  return DayBreakdown(done: done, undone: undone);
}

/// 某天的「已完成记录」条目（总览用）
class CompletionRecord {
  final DateTime date;
  final Task task;
  final int doneAt;

  const CompletionRecord({
    required this.date,
    required this.task,
    required this.doneAt,
  });
}

/// 按日期倒序列出区间内所有已完成记录（含已归档任务）
List<CompletionRecord> completionRecords(
  StatsSnapshot snap, {
  required DateTime from,
  required DateTime to,
}) {
  final byId = <int, Task>{
    for (final t in snap.tasks)
      if (t.id != null) t.id!: t
  };
  final start = todayOnly(from);
  final end = todayOnly(to);
  final out = <CompletionRecord>[];
  snap.completions.forEach((dateStr, ids) {
    final d = _parseDateKey(dateStr);
    if (d == null) return;
    if (d.isBefore(start) || d.isAfter(end)) return;
    for (final id in ids) {
      final t = byId[id];
      if (t == null) continue;
      out.add(CompletionRecord(date: d, task: t, doneAt: 0));
    }
  });
  out.sort((a, b) {
    final c = b.date.compareTo(a.date);
    if (c != 0) return c;
    return (a.task.name).compareTo(b.task.name);
  });
  return out;
}

DateTime? _parseDateKey(String s) {
  final parts = s.split('-');
  if (parts.length != 3) return null;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return null;
  return DateTime(y, m, d);
}
