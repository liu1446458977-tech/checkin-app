/// 周期口径 / 休息日 / 每日统计 / 连续达标 的单元测试。
/// 这些是「总览总结」和后续 AI 总结的地基，必须锁死行为。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:checkin_app/core_logic.dart';
import 'package:checkin_app/models.dart';

/// 默认造一条「重复任务」（每天出现），与旧模型的 daily 行为等价。
Task _task(
  int id, {
  DateTime? createdAt,
  DateTime? ownerDate,
  bool archived = false,
  bool repeatDaily = true,
  DateTime? endDate,
}) =>
    Task(
      id: id,
      name: 't$id',
      ownerDate: ownerDate ?? DateTime(2026, 1, 1),
      repeatDaily: repeatDaily,
      endDate: endDate,
      archived: archived,
      createdAt: createdAt ?? DateTime(2026, 1, 1),
    );

DayStat _stat(DateTime d, {int total = 0, int done = 0, bool rest = false}) =>
    DayStat(date: todayOnly(d), total: total, done: done, isRest: rest);

void main() {
  group('周期口径：月内固定 7 天段', () {
    test('1 月的 7 个周期边界正确', () {
      final w1 = periodFor(PeriodKind.week1, 2026, 1);
      expect(dateKey(w1.start), '2026-01-01');
      expect(dateKey(w1.end), '2026-01-07');

      final w2 = periodFor(PeriodKind.week2, 2026, 1);
      expect(dateKey(w2.start), '2026-01-08');
      expect(dateKey(w2.end), '2026-01-14');

      final w3 = periodFor(PeriodKind.week3, 2026, 1);
      expect(dateKey(w3.start), '2026-01-15');
      expect(dateKey(w3.end), '2026-01-21');

      final w4 = periodFor(PeriodKind.week4, 2026, 1);
      expect(dateKey(w4.start), '2026-01-22');
      expect(dateKey(w4.end), '2026-01-31');

      expect(dateKey(periodFor(PeriodKind.halfFirst, 2026, 1).end), '2026-01-14');
      expect(dateKey(periodFor(PeriodKind.halfSecond, 2026, 1).start), '2026-01-15');
      expect(dateKey(periodFor(PeriodKind.halfSecond, 2026, 1).end), '2026-01-31');
      expect(dateKey(periodFor(PeriodKind.month, 2026, 1).end), '2026-01-31');
    });

    test('第四周吸到月末：2月7天、4月9天、1月10天', () {
      expect(periodFor(PeriodKind.week4, 2026, 2).totalDays, 7); // 2/22-2/28
      expect(periodFor(PeriodKind.week4, 2028, 2).totalDays, 8); // 闰年 2/22-2/29
      expect(periodFor(PeriodKind.week4, 2026, 4).totalDays, 9); // 4/22-4/30
      expect(periodFor(PeriodKind.week4, 2026, 1).totalDays, 10); // 1/22-1/31
    });

    test('4 个周严格拼接成整月：无重叠、无遗漏', () {
      for (final ym in [
        (2026, 1),
        (2026, 2),
        (2028, 2),
        (2026, 4),
        (2026, 12),
      ]) {
        final (y, m) = ym;
        final days = daysInMonth(y, m);
        final covered = <String>{};
        var count = 0;
        for (final k in [
          PeriodKind.week1,
          PeriodKind.week2,
          PeriodKind.week3,
          PeriodKind.week4,
        ]) {
          final p = periodFor(k, y, m);
          for (var d = p.start; !d.isAfter(p.end); d = d.add(const Duration(days: 1))) {
            covered.add(dateKey(d));
            count++;
          }
        }
        expect(count, days, reason: '$y-$m 周段总天数应等于当月天数');
        expect(covered.length, days, reason: '$y-$m 周段之间不应重叠');
      }
    });

    test('前半月 = 第一周 ∪ 第二周；后半月 = 第三周 ∪ 第四周', () {
      for (final ym in [(2026, 1), (2026, 2), (2026, 4)]) {
        final (y, m) = ym;
        Set<String> days(Period p) => {
              for (var d = p.start; !d.isAfter(p.end); d = d.add(const Duration(days: 1)))
                dateKey(d)
            };
        expect(days(periodFor(PeriodKind.halfFirst, y, m)),
            days(periodFor(PeriodKind.week1, y, m))
                .union(days(periodFor(PeriodKind.week2, y, m))));
        expect(days(periodFor(PeriodKind.halfSecond, y, m)),
            days(periodFor(PeriodKind.week3, y, m))
                .union(days(periodFor(PeriodKind.week4, y, m))));
        expect(days(periodFor(PeriodKind.month, y, m)),
            days(periodFor(PeriodKind.halfFirst, y, m))
                .union(days(periodFor(PeriodKind.halfSecond, y, m))));
      }
    });

    test('生成资格：1月3日不能生成第一周，1月7日起可以', () {
      final w1 = periodFor(PeriodKind.week1, 2026, 1);
      expect(w1.isFinishedOn(DateTime(2026, 1, 1)), isFalse);
      expect(w1.isFinishedOn(DateTime(2026, 1, 3)), isFalse);
      expect(w1.isFinishedOn(DateTime(2026, 1, 6)), isFalse);
      expect(w1.isFinishedOn(DateTime(2026, 1, 7)), isTrue);
      expect(w1.isFinishedOn(DateTime(2026, 1, 20)), isTrue);

      // 前半月要到 14 日，整月要到月末
      expect(periodFor(PeriodKind.halfFirst, 2026, 1).isFinishedOn(DateTime(2026, 1, 13)), isFalse);
      expect(periodFor(PeriodKind.halfFirst, 2026, 1).isFinishedOn(DateTime(2026, 1, 14)), isTrue);
      expect(periodFor(PeriodKind.month, 2026, 1).isFinishedOn(DateTime(2026, 1, 30)), isFalse);
      expect(periodFor(PeriodKind.month, 2026, 1).isFinishedOn(DateTime(2026, 1, 31)), isTrue);
    });

    test('weekSegmentOf：按日归到月内固定周', () {
      expect(weekSegmentOf(DateTime(2026, 1, 1)).kind, PeriodKind.week1);
      expect(weekSegmentOf(DateTime(2026, 1, 7)).kind, PeriodKind.week1);
      expect(weekSegmentOf(DateTime(2026, 1, 8)).kind, PeriodKind.week2);
      expect(weekSegmentOf(DateTime(2026, 1, 14)).kind, PeriodKind.week2);
      expect(weekSegmentOf(DateTime(2026, 1, 15)).kind, PeriodKind.week3);
      expect(weekSegmentOf(DateTime(2026, 1, 21)).kind, PeriodKind.week3);
      expect(weekSegmentOf(DateTime(2026, 1, 22)).kind, PeriodKind.week4);
      expect(weekSegmentOf(DateTime(2026, 1, 31)).kind, PeriodKind.week4);
      expect(weekSegmentOf(DateTime(2026, 2, 28)).kind, PeriodKind.week4);
    });

    test('层级：children / parent 自洽', () {
      final month = periodFor(PeriodKind.month, 2026, 1);
      expect(childPeriods(month).map((p) => p.kind).toList(),
          [PeriodKind.halfFirst, PeriodKind.halfSecond]);
      expect(childPeriods(periodFor(PeriodKind.halfFirst, 2026, 1)).map((p) => p.kind).toList(),
          [PeriodKind.week1, PeriodKind.week2]);
      expect(childPeriods(periodFor(PeriodKind.week1, 2026, 1)), isEmpty);

      expect(PeriodKind.week1.parent, PeriodKind.halfFirst);
      expect(PeriodKind.week2.parent, PeriodKind.halfFirst);
      expect(PeriodKind.week3.parent, PeriodKind.halfSecond);
      expect(PeriodKind.week4.parent, PeriodKind.halfSecond);
      expect(PeriodKind.halfFirst.parent, PeriodKind.month);
      expect(PeriodKind.month.parent, isNull);

      expect(PeriodKind.month.isLeaf, isFalse);
      expect(PeriodKind.week3.isLeaf, isTrue);
    });

    test('periodsOfMonth 返回 7 个周期且按时间有序', () {
      final list = periodsOfMonth(2026, 1);
      expect(list.length, 7);
      // 叶子周按时序
      final leaves = list.where((p) => p.kind.isLeaf).toList();
      for (var i = 1; i < leaves.length; i++) {
        expect(leaves[i].start.isAfter(leaves[i - 1].start), isTrue);
      }
      expect(list.where((p) => p.kind == PeriodKind.month).length, 1);
    });

    test('显示名称', () {
      expect(periodFor(PeriodKind.week1, 2026, 1).fullName, '2026年1月第一周');
      expect(periodFor(PeriodKind.halfSecond, 2026, 1).shortName, '1月后半月');
      expect(periodFor(PeriodKind.month, 2026, 1).fullName, '2026年1月整月');
    });
  });

  group('休息日', () {
    test('单日休息日命中', () {
      final rest = {dateKey(DateTime(2026, 1, 10))};
      expect(
          isRestDay(DateTime(2026, 1, 10),
              restDates: rest, weeklyRestWeekdays: const {}),
          isTrue);
      expect(
          isRestDay(DateTime(2026, 1, 11),
              restDates: rest, weeklyRestWeekdays: const {}),
          isFalse);
    });

    test('每周固定休息日命中', () {
      final monday = DateTime(2026, 1, 5);
      expect(monday.weekday, DateTime.monday);
      expect(
          isRestDay(monday,
              restDates: const {}, weeklyRestWeekdays: const {DateTime.monday}),
          isTrue);
      expect(
          isRestDay(monday.add(const Duration(days: 1)),
              restDates: const {}, weeklyRestWeekdays: const {DateTime.monday}),
          isFalse);
    });
  });

  group('每日统计 computeDayStat', () {
    test('休息日不判定达标，完成率不计入', () {
      final tasks = [_task(1)];
      final s = computeDayStat(
        DateTime(2026, 1, 10),
        allTasks: tasks,
        doneTaskIds: {1},
        everDoneTaskIds: {1},
        isRest: true,
      );
      expect(s.total, 1);
      expect(s.done, 1);
      expect(s.isRest, isTrue);
      expect(s.ratio, 0);
      expect(s.allDone, isFalse);
    });

    test('任务在创建之前不出现（历史回看）', () {
      final tasks = [
        _task(1, createdAt: DateTime(2026, 2, 1)),
        _task(2, createdAt: DateTime(2026, 1, 1)),
      ];
      final s = computeDayStat(
        DateTime(2026, 1, 10),
        allTasks: tasks,
        doneTaskIds: const {},
        everDoneTaskIds: const {},
        isRest: false,
      );
      expect(s.total, 1, reason: '2 月才创建的任务不应出现在 1 月');
    });

    test('已归档任务的历史打卡仍计入完成，避免记录丢失', () {
      final tasks = [_task(1, archived: true)];
      final s = computeDayStat(
        DateTime(2026, 1, 10),
        allTasks: tasks,
        doneTaskIds: {1},
        everDoneTaskIds: {1},
        isRest: false,
      );
      expect(s.total, 0, reason: '已归档任务不再算应完成');
      expect(s.done, 1, reason: '但历史打卡要保留');
      expect(s.hasData, isTrue);
      expect(s.ratio, 1);
    });

    test('周期任务：完成一次即达成，之后每天都算完成（不拉低完成率）', () {
      final tasks = [
        _task(1, repeatDaily: false, endDate: DateTime(2026, 1, 20)),
      ];
      final s = computeDayStat(
        DateTime(2026, 1, 10),
        allTasks: tasks,
        doneTaskIds: const {}, // 1/10 当天没有打卡
        everDoneTaskIds: {1}, // 但早在 1/3 就达成了
        isRest: false,
      );
      expect(s.total, 1);
      expect(s.done, 1);
      expect(s.allDone, isTrue);
    });

    test('一天的任务：第二天不再计入应完成（不复制）', () {
      final tasks = [
        Task(
          id: 5,
          name: '一天的任务',
          ownerDate: DateTime(2026, 1, 1),
          createdAt: DateTime(2026, 1, 1),
        ),
      ];
      final day1 = computeDayStat(
        DateTime(2026, 1, 1),
        allTasks: tasks,
        doneTaskIds: {5},
        everDoneTaskIds: {5},
        isRest: false,
      );
      expect(day1.total, 1);
      expect(day1.done, 1);
      final day2 = computeDayStat(
        DateTime(2026, 1, 2),
        allTasks: tasks,
        doneTaskIds: const {},
        everDoneTaskIds: {5},
        isRest: false,
      );
      expect(day2.total, 0, reason: '第二天不该再出现这条任务');
      expect(day2.hasData, isFalse);
    });

    test('重复任务：昨天完成不影响今天的完成判定', () {
      final tasks = [_task(1)];
      final today = computeDayStat(
        DateTime(2026, 1, 2),
        allTasks: tasks,
        doneTaskIds: const {}, // 今天还没打
        everDoneTaskIds: {1}, // 昨天打过
        isRest: false,
      );
      expect(today.total, 1);
      expect(today.done, 0);
      expect(today.allDone, isFalse);
    });
  });

  group('连续达标 calcStreak（休息日不断签）', () {
    DayStat Function(DateTime) statter(
      Map<String, DayStat> map, {
      Set<int> weeklyRest = const {},
    }) =>
        (d) =>
            map[dateKey(d)] ??
            DayStat(date: todayOnly(d), total: 0, done: 0, isRest: weeklyRest.contains(d.weekday));

    test('连续三天全部完成 → 3', () {
      final map = {
        '2026-01-10': _stat(DateTime(2026, 1, 10), total: 2, done: 2),
        '2026-01-09': _stat(DateTime(2026, 1, 9), total: 2, done: 2),
        '2026-01-08': _stat(DateTime(2026, 1, 8), total: 1, done: 1),
      };
      expect(calcStreak(statter(map), DateTime(2026, 1, 10)), 3);
    });

    test('中间夹一个休息日：不断签，也不计入天数', () {
      final map = {
        '2026-01-10': _stat(DateTime(2026, 1, 10), total: 2, done: 2),
        '2026-01-09': _stat(DateTime(2026, 1, 9), total: 2, done: 2),
        '2026-01-08': _stat(DateTime(2026, 1, 8), total: 3, done: 0, rest: true),
        '2026-01-07': _stat(DateTime(2026, 1, 7), total: 2, done: 2),
        '2026-01-06': _stat(DateTime(2026, 1, 6), total: 2, done: 2),
      };
      // 10,9 + 跳过 8(休息) + 7,6 = 4
      expect(calcStreak(statter(map), DateTime(2026, 1, 10)), 4);
    });

    test('中间有一天没做完 → 断签', () {
      final map = {
        '2026-01-10': _stat(DateTime(2026, 1, 10), total: 2, done: 2),
        '2026-01-09': _stat(DateTime(2026, 1, 9), total: 2, done: 1),
        '2026-01-08': _stat(DateTime(2026, 1, 8), total: 2, done: 2),
      };
      expect(calcStreak(statter(map), DateTime(2026, 1, 10)), 1);
    });

    test('今天还没做完 → 从昨天起算（避免中午归零）', () {
      final map = {
        '2026-01-10': _stat(DateTime(2026, 1, 10), total: 4, done: 1),
        '2026-01-09': _stat(DateTime(2026, 1, 9), total: 2, done: 2),
        '2026-01-08': _stat(DateTime(2026, 1, 8), total: 2, done: 2),
      };
      expect(calcStreak(statter(map), DateTime(2026, 1, 10)), 2);
    });

    test('今天是休息日 → 从昨天起算，且今天不计入', () {
      final map = {
        '2026-01-10': _stat(DateTime(2026, 1, 10), total: 3, done: 0, rest: true),
        '2026-01-09': _stat(DateTime(2026, 1, 9), total: 2, done: 2),
        '2026-01-08': _stat(DateTime(2026, 1, 8), total: 2, done: 2),
      };
      expect(calcStreak(statter(map), DateTime(2026, 1, 10)), 2);
    });

    test('遇到没有任何任务的一天 → 停止', () {
      final map = {
        '2026-01-10': _stat(DateTime(2026, 1, 10), total: 2, done: 2),
        '2026-01-09': _stat(DateTime(2026, 1, 9), total: 2, done: 2),
      };
      expect(calcStreak(statter(map), DateTime(2026, 1, 10)), 2);
    });
  });

  group('周期聚合 aggregatePeriod', () {
    test('汇总完成率、休息日、睡前总结天数', () {
      final p = periodFor(PeriodKind.week1, 2026, 1); // 1/1 - 1/7
      final map = {
        '2026-01-01': _stat(DateTime(2026, 1, 1), total: 2, done: 2),
        '2026-01-02': _stat(DateTime(2026, 1, 2), total: 2, done: 1),
        '2026-01-03': _stat(DateTime(2026, 1, 3), total: 2, done: 0, rest: true),
        // 1/4 - 1/7 没有任何任务
      };
      final notes = {'2026-01-01', '2026-01-02', '2026-01-03'};
      final st = aggregatePeriod(
        p,
        statAt: (d) => map[dateKey(d)] ?? _stat(d),
        noteDates: notes,
      );
      expect(st.totalDays, 7);
      expect(st.restDays, 1);
      expect(st.activeDays, 2, reason: '只有 1/1、1/2 有任务');
      expect(st.totalSlots, 4);
      expect(st.doneSlots, 3);
      expect(st.perfectDays, 1);
      expect(st.noteDays, 3);
      expect(st.percent, 75);
    });

    test('until 参数：进行中的周期只统计到今天', () {
      final p = periodFor(PeriodKind.week1, 2026, 1); // 1/1 - 1/7
      var calls = <String>[];
      final st = aggregatePeriod(
        p,
        statAt: (d) {
          calls.add(dateKey(d));
          return _stat(d, total: 1, done: 1);
        },
        noteDates: const {},
        until: DateTime(2026, 1, 3),
      );
      expect(calls, ['2026-01-01', '2026-01-02', '2026-01-03']);
      expect(st.activeDays, 3);
      expect(st.totalDays, 7, reason: '周期总天数仍是整段');
    });
  });

  group('DailyNote 模型', () {
    test('isEmpty / filledCount / preview', () {
      const empty = DailyNote(date: '2026-01-01');
      expect(empty.isEmpty, isTrue);
      expect(empty.isNotEmpty, isFalse);
      expect(empty.preview, '');

      const one = DailyNote(date: '2026-01-01', blocker: '卡在 XXX');
      expect(one.isEmpty, isFalse);
      expect(one.filledCount, 1);
      expect(one.preview, '卡在 XXX');

      const all = DailyNote(
          date: '2026-01-01', gain: 'a', blocker: 'b', tomorrow: 'c', extra: 'd');
      expect(all.filledCount, 4);
      expect(all.preview, 'a');
    });

    test('toRow / fromRow 往返一致', () {
      const n = DailyNote(
        date: '2026-01-01',
        gain: '收获',
        blocker: '卡点',
        tomorrow: '明天',
        extra: '其他',
        updatedAt: 123,
      );
      final back = DailyNote.fromRow(n.toRow());
      expect(back.date, n.date);
      expect(back.gain, n.gain);
      expect(back.blocker, n.blocker);
      expect(back.tomorrow, n.tomorrow);
      expect(back.extra, n.extra);
      expect(back.updatedAt, n.updatedAt);
    });
  });
}
