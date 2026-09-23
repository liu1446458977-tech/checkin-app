/// 纯业务逻辑：任务出现判断、完成判断、22:00 提醒判断、语录抽取。
/// 全部为无副作用纯函数，便于单元测试。
library;

import 'dart:math';

import 'models.dart';

String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime todayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// 统计快照的回溯窗口（天）：连续达标与总览统计都用它，
/// 两处必须一致，否则会出现「快照里没数据、循环还在空转」的静默截断。
const int kStreakLookbackDays = 400;

/// ============================================================
/// 排期与完成判定（纯函数，全部有单测锁住）
///
/// 任务形态由「每天重复 / 截止日」两个属性派生，不再有独立的类型字段：
///   一天的任务  无重复、无截止   → 只在归属日出现，第二天不会复制
///   重复任务    repeatDaily      → 从归属日起每天都出现
///   周期任务    有截止日（跨天大事）→ 起止日之间每天都出现，完成一次即达成
/// ============================================================

/// 该任务在 [d] 这天的「计划」是否覆盖（**不看归档、也不看是否完成**）。
/// 今日列表、历史回看、统计全部走这一个入口，口径不可能再打架。
bool scheduledOn(Task t, DateTime d) {
  final day = todayOnly(d);
  final start = todayOnly(t.ownerDate);
  if (day.isBefore(start)) return false;
  final end = t.endDate == null ? null : todayOnly(t.endDate!);
  if (end != null && day.isAfter(end)) return false;
  if (t.repeatDaily) return true; // 重复任务：每天都出现
  if (end != null) return true; // 周期任务：起止日之间每天都出现
  return day == start; // 一天的任务：只在归属日出现
}

/// 「今日」列表口径：排期覆盖 且 未归档。
bool appearsToday(Task t, DateTime d) => !t.archived && scheduledOn(t, d);

/// 「历史回看」口径：当天排期覆盖（**含已归档**）或 当天确实打过卡。
/// 归档只应该影响今日列表，绝不能让人看不到历史。
bool appearedOnHistory(Task t, DateTime d, {required bool doneThatDay}) =>
    scheduledOn(t, d) || doneThatDay;

/// 单条任务在某天是否「显示为已完成」：
/// - 重复任务：每天独立打卡，只看当天那张卡
/// - 周期任务：完成一次即达成，此后每天都显示为已完成（直到周期结束）
/// - 一天的任务：只看当天
bool taskDoneForDisplay(Task t, DateTime d, {required Set<String> doneDates}) {
  if (t.repeatDaily) return doneDates.contains(dateKey(d));
  if (t.endDate != null) return doneDates.isNotEmpty;
  return doneDates.contains(dateKey(d));
}

/// 任务 [t] 在 [d] 是否已完成（completions 表里有记录）。
bool taskDoneOnDate(Set<String> doneDates, DateTime d) =>
    doneDates.contains(dateKey(d));

/// 排期的展示文案：一天的任务「9月19日」、周期任务「9月19日–9月28日」。
String scheduleLabel(Task t) {
  final start = '${t.ownerDate.month}月${t.ownerDate.day}日';
  if (t.endDate == null) return start;
  return '$start–${t.endDate!.month}月${t.endDate!.day}日';
}

/// 从语录库中抽取一条：优先避开最近用过的 [recentIds]（不重复轮播）。
Quote pickQuote(List<Quote> all, Set<String> recentIds) {
  final fresh = all.where((q) => !recentIds.contains(q.text)).toList();
  final pool = fresh.isEmpty ? all : fresh;
  final r = Random();
  return pool[r.nextInt(pool.length)];
}

// ============================================================
// 周期（与月历严格对齐的固定 7 天段）
//
//   X月第一周  1 日 ~ 7 日      ┐
//   X月第二周  8 日 ~ 14 日     ┘→ X月前半月 1 日 ~ 14 日   ┐
//   X月第三周  15 日 ~ 21 日    ┐                            ┘→ X月整月
//   X月第四周  22 日 ~ 月末     ┘→ X月后半月 15 日 ~ 月末
//
// 1-7 ∪ 8-14 = 1-14，15-21 ∪ 22-月末 = 15-月末：严格无重叠无遗漏，
// 所以「2 个周凑 1 个半月、2 个半月凑 1 个月」在日历上精确成立。
// 代价：第四周是 7~10 天（2 月 7 天、1 月 10 天），不是恒定 7 天。
// ============================================================

enum PeriodKind {
  week1,
  week2,
  week3,
  week4,
  halfFirst,
  halfSecond,
  month;

  /// 是否是最底层（直接用逐日数据，而不是汇总下层总结）
  bool get isLeaf => this == week1 || this == week2 || this == week3 || this == week4;

  /// 短名，如「1月第一周」
  String shortName(int month) => switch (this) {
        PeriodKind.week1 => '$month月第一周',
        PeriodKind.week2 => '$month月第二周',
        PeriodKind.week3 => '$month月第三周',
        PeriodKind.week4 => '$month月第四周',
        PeriodKind.halfFirst => '$month月前半月',
        PeriodKind.halfSecond => '$month月后半月',
        PeriodKind.month => '$month月整月',
      };

  /// 该周期由哪些下层周期汇总而来（叶子层为空）
  List<PeriodKind> get children => switch (this) {
        PeriodKind.halfFirst => const [PeriodKind.week1, PeriodKind.week2],
        PeriodKind.halfSecond => const [PeriodKind.week3, PeriodKind.week4],
        PeriodKind.month => const [PeriodKind.halfFirst, PeriodKind.halfSecond],
        _ => const [],
      };

  /// 上级周期
  PeriodKind? get parent => switch (this) {
        PeriodKind.week1 || PeriodKind.week2 => PeriodKind.halfFirst,
        PeriodKind.week3 || PeriodKind.week4 => PeriodKind.halfSecond,
        PeriodKind.halfFirst || PeriodKind.halfSecond => PeriodKind.month,
        PeriodKind.month => null,
      };
}

int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// 一个具体周期：类型 + 年月 + 起止日期（含首尾）
class Period {
  final PeriodKind kind;
  final int year;
  final int month;
  final DateTime start;
  final DateTime end;

  const Period(this.kind, this.year, this.month, this.start, this.end);

  /// 「1月第一周」
  String get shortName => kind.shortName(month);

  /// 「2026年1月第一周」
  String get fullName => '$year年$shortName';

  /// 「2026-01-01 ~ 2026-01-07」
  String get rangeText => '${dateKey(start)} ~ ${dateKey(end)}';

  /// 「1月3日结束」/「进行中」
  String get endText => '${end.month}月${end.day}日结束';

  int get totalDays => end.difference(start).inDays + 1;

  bool contains(DateTime d) {
    final t = todayOnly(d);
    return !t.isBefore(start) && !t.isAfter(end);
  }

  /// 周期是否已结束（结束日 ≤ 今天）。
  /// 例：1 月第一周结束日是 1 月 7 日，所以 1 月 3 日不可生成，1 月 7 日起可生成。
  bool isFinishedOn(DateTime today) => !todayOnly(today).isBefore(end);

  @override
  bool operator ==(Object other) =>
      other is Period &&
      other.kind == kind &&
      other.year == year &&
      other.month == month;

  @override
  int get hashCode => Object.hash(kind, year, month);

  @override
  String toString() => '$fullName($rangeText)';
}

/// 取某年某月的指定周期
Period periodFor(PeriodKind kind, int year, int month) {
  final last = daysInMonth(year, month);
  DateTime d(int day) => DateTime(year, month, day);
  switch (kind) {
    case PeriodKind.week1:
      return Period(kind, year, month, d(1), d(7));
    case PeriodKind.week2:
      return Period(kind, year, month, d(8), d(14));
    case PeriodKind.week3:
      return Period(kind, year, month, d(15), d(21));
    case PeriodKind.week4:
      return Period(kind, year, month, d(22), d(last));
    case PeriodKind.halfFirst:
      return Period(kind, year, month, d(1), d(14));
    case PeriodKind.halfSecond:
      return Period(kind, year, month, d(15), d(last));
    case PeriodKind.month:
      return Period(kind, year, month, d(1), d(last));
  }
}

/// 某年某月的全部 7 个周期（按时间顺序）
List<Period> periodsOfMonth(int year, int month) => [
      for (final k in const [
        PeriodKind.week1,
        PeriodKind.week2,
        PeriodKind.halfFirst,
        PeriodKind.week3,
        PeriodKind.week4,
        PeriodKind.halfSecond,
        PeriodKind.month,
      ])
        periodFor(k, year, month),
    ];

/// 指定日期所属的「月内固定周」（总览「本期」用它）
Period weekSegmentOf(DateTime d) {
  final day = d.day;
  final kind = day <= 7
      ? PeriodKind.week1
      : day <= 14
          ? PeriodKind.week2
          : day <= 21
              ? PeriodKind.week3
              : PeriodKind.week4;
  return periodFor(kind, d.year, d.month);
}

/// 该周期的下层周期（叶子层返回空）
List<Period> childPeriods(Period p) =>
    [for (final k in p.kind.children) periodFor(k, p.year, p.month)];

// ============================================================
// 休息日
// ============================================================

/// 某天是否休息日：命中「单日休息」或「每周固定休息」
bool isRestDay(
  DateTime d, {
  required Set<String> restDates,
  required Set<int> weeklyRestWeekdays,
}) {
  if (restDates.contains(dateKey(d))) return true;
  return weeklyRestWeekdays.contains(d.weekday);
}

// ============================================================
// 每日统计
// ============================================================

class DayStat {
  final DateTime date;
  final int total; // 当天「应当出现」的任务数
  final int done; // 当天实际完成的（含已归档任务的历史打卡）
  final bool isRest;

  const DayStat({
    required this.date,
    required this.total,
    required this.done,
    required this.isRest,
  });

  /// 这天是否有任何可看的数据
  bool get hasData => total > 0 || done > 0;

  /// 完成率：休息日不计入分母（返回 0，由 UI 单独配色）
  double get ratio {
    if (isRest) return 0;
    if (total == 0) return done > 0 ? 1 : 0;
    final r = done / total;
    return r > 1 ? 1 : r;
  }

  /// 这天是否「该做的都做完了」。休息日不算达标。
  bool get allDone => !isRest && total > 0 && done >= total;
}

/// 计算某天的统计。全部为纯函数，便于单测。
///
/// 口径统一为「排期覆盖」：归档任务不计入当日总数（否则一归档完成率就变了），
/// 但它在当天真实打过的卡仍然算完成，历史不会凭空少一块。
DayStat computeDayStat(
  DateTime d, {
  required List<Task> allTasks,
  required Set<int> doneTaskIds,
  required Set<int> everDoneTaskIds,
  required bool isRest,
}) {
  final day = todayOnly(d);
  final byId = <int, Task>{
    for (final t in allTasks)
      if (t.id != null) t.id!: t
  };

  bool doneFor(Task t) {
    // 重复任务与一天的任务：只认当天的打卡记录
    if (t.repeatDaily) return doneTaskIds.contains(t.id);
    // 周期任务：完成一次即达成，此后每天都算已完成（不会拉低完成率）
    if (t.endDate != null) return everDoneTaskIds.contains(t.id);
    return doneTaskIds.contains(t.id);
  }

  var total = 0;
  var done = 0;
  for (final t in allTasks) {
    // 历史回看：任务在创建之前不应当出现
    if (todayOnly(t.createdAt).isAfter(day)) continue;
    if (!scheduledOn(t, day)) continue;
    if (t.archived) continue; // 已归档不计入当日总数
    total++;
    if (doneFor(t)) done++;
  }
  // 已归档 / 当天不该出现但确实打过卡的任务，也算完成记录，避免历史丢失
  for (final id in doneTaskIds) {
    final t = byId[id];
    if (t == null) continue;
    if (todayOnly(t.createdAt).isAfter(day)) continue;
    if (scheduledOn(t, day) && !t.archived) continue; // 已在上面计过
    done++;
  }
  return DayStat(date: day, total: total, done: done, isRest: isRest);
}

/// 连续达标天数。休息日既不算断签、也不计入达标天数。
int calcStreak(DayStat Function(DateTime) statAt, DateTime today) {
  var cursor = todayOnly(today);
  final t = statAt(cursor);
  // 今天还没全部完成（或今天休息）→ 从昨天开始数，避免中午就归零
  if (!(t.hasData && t.allDone)) {
    cursor = cursor.subtract(const Duration(days: 1));
  }
  var count = 0;
  // 循环上限与统计快照的回溯窗口一致（kStreakLookbackDays）：
  // 快照之外没有数据，多跑也是空转，索性让两处口径显式绑定。
  for (var i = 0; i < kStreakLookbackDays; i++) {
    final s = statAt(cursor);
    if (s.isRest) {
      // 休息日：跳过，不断签
      cursor = cursor.subtract(const Duration(days: 1));
      continue;
    }
    if (!s.hasData) break; // 这天没有任何任务 → 到此为止
    if (!s.allDone) break; // 有未完成 → 断签
    count++;
    cursor = cursor.subtract(const Duration(days: 1));
  }
  return count;
}

/// 周期聚合统计（总览「本期小结」与 AI 提示词共用）
class PeriodStats {
  final int totalDays;
  final int restDays;
  final int activeDays; // 有任务的天数（不含休息日）
  final int totalSlots; // 累计「应当完成」数
  final int doneSlots; // 累计完成数
  final int noteDays; // 写了睡前总结的天数
  final int perfectDays; // 全部完成的天数

  const PeriodStats({
    required this.totalDays,
    required this.restDays,
    required this.activeDays,
    required this.totalSlots,
    required this.doneSlots,
    required this.noteDays,
    required this.perfectDays,
  });

  double get ratio => totalSlots == 0 ? 0 : doneSlots / totalSlots;
  int get percent => (ratio * 100).round();

  static const empty = PeriodStats(
    totalDays: 0,
    restDays: 0,
    activeDays: 0,
    totalSlots: 0,
    doneSlots: 0,
    noteDays: 0,
    perfectDays: 0,
  );
}

PeriodStats aggregatePeriod(
  Period p, {
  required DayStat Function(DateTime) statAt,
  required Set<String> noteDates,
  DateTime? until,
}) {
  final last = until == null ? p.end : todayOnly(until);
  var rest = 0, active = 0, slots = 0, done = 0, notes = 0, perfect = 0;
  for (var d = p.start;
      !d.isAfter(p.end) && !d.isAfter(last);
      d = d.add(const Duration(days: 1))) {
    final s = statAt(d);
    if (s.isRest) {
      rest++;
    } else if (s.hasData) {
      active++;
      slots += s.total;
      done += s.done;
      if (s.allDone) perfect++;
    }
    if (noteDates.contains(dateKey(d))) notes++;
  }
  final totalDays = p.end.difference(p.start).inDays + 1;
  return PeriodStats(
    totalDays: totalDays,
    restDays: rest,
    activeDays: active,
    totalSlots: slots,
    doneSlots: done,
    noteDays: notes,
    perfectDays: perfect,
  );
}
