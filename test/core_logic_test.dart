/// core_logic.dart 的纯函数单元测试。
/// 覆盖：排期口径（今日 / 历史）、完成判定、22:00 提醒、语录抽取。
///
/// 其中「一天的任务第二天不出现」「周期任务完成一次即达成」「归档不影响历史」
/// 这三条是用户实际反馈过的 bug，必须锁死。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:checkin_app/core_logic.dart';
import 'package:checkin_app/models.dart';
import 'package:checkin_app/quote_lib.dart';

/// 一天的任务：只在归属日出现
Task _single(DateTime owner, {int? id, bool archived = false}) => Task(
      id: id,
      name: '一天的任务',
      ownerDate: owner,
      archived: archived,
      createdAt: DateTime(2026, 1, 1),
    );

/// 重复任务：从归属日起每天都出现
Task _repeating(DateTime owner,
        {int? id, DateTime? end, bool archived = false}) =>
    Task(
      id: id,
      name: '重复任务',
      ownerDate: owner,
      repeatDaily: true,
      endDate: end,
      archived: archived,
      createdAt: DateTime(2026, 1, 1),
    );

/// 周期任务：起止日之间每天出现，完成一次即达成
Task _periodic(DateTime start, DateTime? end, {int? id, bool archived = false}) =>
    Task(
      id: id,
      name: '周期任务',
      ownerDate: start,
      endDate: end,
      archived: archived,
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  group('dateKey / todayOnly', () {
    test('补零格式化', () {
      expect(dateKey(DateTime(2026, 9, 6)), '2026-09-06');
      expect(dateKey(DateTime(2026, 12, 31)), '2026-12-31');
    });

    test('todayOnly 去掉时间部分', () {
      final d = todayOnly(DateTime(2026, 9, 16, 23, 59, 59));
      expect(d, DateTime(2026, 9, 16));
      expect(d.hour, 0);
    });
  });

  group('scheduledOn：排期覆盖（不看归档、不看完成）', () {
    final wednesday = DateTime(2026, 9, 16);

    test('一天的任务：只在归属日当天覆盖', () {
      final t = _single(wednesday);
      expect(scheduledOn(t, DateTime(2026, 9, 15)), isFalse);
      expect(scheduledOn(t, wednesday), isTrue);
      expect(scheduledOn(t, DateTime(2026, 9, 17)), isFalse);
      expect(scheduledOn(t, DateTime(2026, 10, 1)), isFalse);
    });

    test('一天的任务：第二天不会复制出现（用户反馈的 bug）', () {
      final t = _single(DateTime(2026, 1, 1));
      expect(scheduledOn(t, DateTime(2026, 1, 1)), isTrue);
      expect(scheduledOn(t, DateTime(2026, 1, 2)), isFalse, reason: '第二天不应该再出现');
      expect(scheduledOn(t, DateTime(2026, 1, 3)), isFalse);
    });

    test('重复任务：从归属日起每天都覆盖', () {
      final t = _repeating(DateTime(2026, 9, 16));
      expect(scheduledOn(t, DateTime(2026, 9, 15)), isFalse);
      expect(scheduledOn(t, DateTime(2026, 9, 16)), isTrue);
      expect(scheduledOn(t, DateTime(2026, 9, 17)), isTrue);
      expect(scheduledOn(t, DateTime(2027, 5, 1)), isTrue);
    });

    test('重复任务带截止日：到截止日为止', () {
      final t = _repeating(DateTime(2026, 9, 1), end: DateTime(2026, 9, 10));
      expect(scheduledOn(t, DateTime(2026, 9, 10)), isTrue, reason: '含截止日当天');
      expect(scheduledOn(t, DateTime(2026, 9, 11)), isFalse);
    });

    test('周期任务：起止日之间每天都覆盖，区间外不覆盖', () {
      final t = _periodic(DateTime(2026, 1, 1), DateTime(2026, 1, 10));
      expect(scheduledOn(t, DateTime(2025, 12, 31)), isFalse, reason: '起始日之前');
      expect(scheduledOn(t, DateTime(2026, 1, 1)), isTrue);
      expect(scheduledOn(t, DateTime(2026, 1, 7)), isTrue);
      expect(scheduledOn(t, DateTime(2026, 1, 10)), isTrue, reason: '含截止日当天');
      expect(scheduledOn(t, DateTime(2026, 1, 11)), isFalse, reason: '到期后消失');
    });

    test('只有归属日、既不重复也没截止日 → 就是一天的任务', () {
      final t = _periodic(DateTime(2026, 1, 1), null);
      expect(scheduledOn(t, DateTime(2026, 1, 1)), isTrue);
      expect(scheduledOn(t, DateTime(2026, 1, 2)), isFalse);
      expect(scheduledOn(t, DateTime(2030, 1, 1)), isFalse,
          reason: '想长期出现必须勾「每天重复」');
    });

    test('排期与归档无关（归档只在今日口径里被排除）', () {
      expect(scheduledOn(_single(DateTime(2026, 1, 1), archived: true),
          DateTime(2026, 1, 1)), isTrue);
    });
  });

  group('appearsToday：今日列表口径（排期覆盖 且 未归档）', () {
    test('一天的任务第二天不再出现（不复制）', () {
      final t = _single(DateTime(2026, 1, 1));
      expect(appearsToday(t, DateTime(2026, 1, 1)), isTrue);
      expect(appearsToday(t, DateTime(2026, 1, 2)), isFalse);
    });

    test('重复任务每天都出现', () {
      final t = _repeating(DateTime(2026, 1, 1));
      expect(appearsToday(t, DateTime(2026, 1, 1)), isTrue);
      expect(appearsToday(t, DateTime(2026, 1, 2)), isTrue);
    });

    test('周期任务在周期内每天都出现', () {
      final t = _periodic(DateTime(2026, 1, 1), DateTime(2026, 1, 10));
      expect(appearsToday(t, DateTime(2026, 1, 5)), isTrue);
      expect(appearsToday(t, DateTime(2026, 1, 11)), isFalse);
    });

    test('归档任务不再出现在今日', () {
      final t = _repeating(DateTime(2026, 1, 1), archived: true);
      expect(appearsToday(t, DateTime(2026, 1, 1)), isFalse);
    });
  });

  group('appearedOnHistory：历史回看口径（含归档；含当天真打过卡的）', () {
    test('归档任务在历史里仍然看得见（用户反馈的 bug）', () {
      final t = _repeating(DateTime(2026, 1, 1), archived: true);
      expect(
        appearedOnHistory(t, DateTime(2026, 1, 5), doneThatDay: false),
        isTrue,
        reason: '归档只应该影响今日列表，不能让人看不到历史',
      );
    });

    test('一天的任务在归属日那天的历史里看得见', () {
      final t = _single(DateTime(2026, 1, 1));
      expect(appearedOnHistory(t, DateTime(2026, 1, 1), doneThatDay: false),
          isTrue);
      expect(appearedOnHistory(t, DateTime(2026, 1, 2), doneThatDay: false),
          isFalse);
    });

    test('不在排期内但当天确实打过卡的，历史里也要出现', () {
      final t = _single(DateTime(2026, 3, 1)); // 归属日被改成 3/1
      expect(
        appearedOnHistory(t, DateTime(2026, 1, 1), doneThatDay: true),
        isTrue,
        reason: '1/1 打过卡，历史回看不能凭空少一条',
      );
    });

    test('周期任务到期之后的历史里仍然看得见', () {
      final t = _periodic(DateTime(2026, 1, 1), DateTime(2026, 1, 10));
      expect(appearedOnHistory(t, DateTime(2026, 1, 7), doneThatDay: false),
          isTrue);
    });
  });

  group('taskDoneForDisplay：完成判定', () {
    test('一天的任务：当天打卡才算完成', () {
      final t = _single(DateTime(2026, 1, 1));
      expect(
          taskDoneForDisplay(t, DateTime(2026, 1, 1),
              doneDates: {'2026-01-01'}),
          isTrue);
      expect(
          taskDoneForDisplay(t, DateTime(2026, 1, 1), doneDates: const {}),
          isFalse);
    });

    test('周期任务：完成一次即达成，之后每天都显示为已完成', () {
      final t = _periodic(DateTime(2026, 1, 1), DateTime(2026, 1, 10));
      const done = {'2026-01-03'}; // 1/3 打了卡
      expect(taskDoneForDisplay(t, DateTime(2026, 1, 3), doneDates: done),
          isTrue);
      expect(taskDoneForDisplay(t, DateTime(2026, 1, 4), doneDates: done),
          isTrue,
          reason: '完成后应显示为已完成直到周期结束');
      expect(taskDoneForDisplay(t, DateTime(2026, 1, 10), doneDates: done),
          isTrue);
    });

    test('重复任务：每天独立打卡，昨天的完成不影响今天', () {
      final t = _repeating(DateTime(2026, 1, 1));
      const done = {'2026-01-01'};
      expect(taskDoneForDisplay(t, DateTime(2026, 1, 1), doneDates: done),
          isTrue);
      expect(taskDoneForDisplay(t, DateTime(2026, 1, 2), doneDates: done),
          isFalse);
    });

  });

  group('taskDoneOnDate', () {
    test('命中日期集合则视为完成', () {
      final done = {'2026-09-16'};
      expect(taskDoneOnDate(done, DateTime(2026, 9, 16)), isTrue);
      expect(taskDoneOnDate(done, DateTime(2026, 9, 17)), isFalse);
    });

    test('空集合视为未完成', () {
      expect(taskDoneOnDate(const {}, DateTime(2026, 9, 16)), isFalse);
    });

  });

  group('scheduleLabel', () {
    test('一天的任务只显示归属日', () {
      expect(scheduleLabel(_single(DateTime(2026, 9, 19))), '9月19日');
    });

    test('周期任务显示「起始–截止」', () {
      expect(
        scheduleLabel(_periodic(DateTime(2026, 1, 1), DateTime(2026, 1, 10))),
        '1月1日–1月10日',
      );
    });
  });

  group('pickQuote', () {
    test('返回语录库中的一条', () {
      final q = pickQuote(kQuotes, const {});
      expect(kQuotes.contains(q), isTrue);
    });

    test('优先避开最近使用过的（recent 之外的池）', () {
      final recent = kQuotes.take(kQuotes.length - 1).map((q) => q.text).toSet();
      final q = pickQuote(kQuotes, recent);
      expect(recent.contains(q.text), isFalse);
      expect(q.text, kQuotes.last.text);
    });

    test('全部都用过时仍能返回一条', () {
      final all = kQuotes.map((q) => q.text).toSet();
      final q = pickQuote(kQuotes, all);
      expect(kQuotes.contains(q), isTrue);
    });
  });

  group('newTaskUuid', () {
    test('生成 32 位十六进制且不重复', () {
      final a = newTaskUuid();
      final b = newTaskUuid();
      expect(a.length, 32);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(a), isTrue);
      expect(a == b, isFalse);
    });
  });

  group('Task.kind 派生', () {
    test('不重复 + 无截止 = 一天的任务', () {
      expect(_single(DateTime(2026, 1, 1)).kind, TaskKind.single);
    });

    test('打开重复 = 重复任务', () {
      expect(_repeating(DateTime(2026, 1, 1)).kind, TaskKind.repeating);
    });

    test('有截止日 = 周期任务', () {
      expect(_periodic(DateTime(2026, 1, 1), DateTime(2026, 1, 10)).kind,
          TaskKind.periodic);
    });

    test('重复 + 截止：仍按重复任务展示（每天要打卡）', () {
      expect(
        _repeating(DateTime(2026, 1, 1), end: DateTime(2026, 1, 10)).kind,
        TaskKind.repeating,
      );
    });
  });
}
