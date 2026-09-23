/// 「归属日 + 截止日」区间约束测试。
///
/// 新模型下：一天的任务只覆盖归属日；重复任务从归属日起每天覆盖；
/// 周期任务（有截止日）在归属日~截止日之间每天覆盖，到期即消失。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:checkin_app/core_logic.dart';
import 'package:checkin_app/models.dart';

Task _owner(DateTime owner) => Task(
      id: 1,
      name: '一天的任务',
      ownerDate: owner,
      createdAt: DateTime(2026, 1, 1),
    );

Task _periodic(DateTime start, DateTime? end) => Task(
      id: 2,
      name: '周期任务',
      ownerDate: start,
      endDate: end,
      createdAt: DateTime(2026, 1, 1),
    );

Task _repeating(DateTime start, {DateTime? end}) => Task(
      id: 3,
      name: '重复任务',
      ownerDate: start,
      repeatDaily: true,
      endDate: end,
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  group('截止日', () {
    test('截止日当天仍出现，之后不再出现', () {
      final t = _periodic(DateTime(2026, 1, 1), DateTime(2026, 1, 20));
      expect(scheduledOn(t, DateTime(2026, 1, 19)), isTrue);
      expect(scheduledOn(t, DateTime(2026, 1, 20)), isTrue, reason: '含截止日当天');
      expect(scheduledOn(t, DateTime(2026, 1, 21)), isFalse);
      expect(scheduledOn(t, DateTime(2026, 3, 1)), isFalse);
    });

    test('到期未完成 → 从今日消失（历史仍可在 day_detail 里看到）', () {
      final t = _periodic(DateTime(2026, 1, 1), DateTime(2026, 1, 20));
      expect(appearsToday(t, DateTime(2026, 1, 21)), isFalse);
      expect(
        appearedOnHistory(t, DateTime(2026, 1, 15), doneThatDay: false),
        isTrue,
        reason: '历史回看仍然要看得到那条没完成的大事',
      );
    });

    test('截止日留空 + 不重复 = 一天的任务（长期出现要勾「每天重复」）', () {
      final single = _periodic(DateTime(2026, 1, 1), null);
      expect(scheduledOn(single, DateTime(2026, 1, 1)), isTrue);
      expect(scheduledOn(single, DateTime(2030, 1, 1)), isFalse);

      final always = _repeating(DateTime(2026, 1, 1));
      expect(scheduledOn(always, DateTime(2030, 1, 1)), isTrue);
    });
  });

  group('归属日（起始日）', () {
    test('归属日之前不出现', () {
      final t = _periodic(DateTime(2026, 2, 1), DateTime(2026, 3, 1));
      expect(scheduledOn(t, DateTime(2026, 1, 31)), isFalse);
      expect(scheduledOn(t, DateTime(2026, 2, 1)), isTrue);
      expect(scheduledOn(t, DateTime(2026, 2, 2)), isTrue);
    });

    test('一天的任务：归属日之前和之后都不出现', () {
      final t = _owner(DateTime(2026, 2, 1));
      expect(scheduledOn(t, DateTime(2026, 1, 31)), isFalse);
      expect(scheduledOn(t, DateTime(2026, 2, 1)), isTrue);
      expect(scheduledOn(t, DateTime(2026, 2, 2)), isFalse);
    });

    test('重复任务：归属日之前不出现，之后每天出现', () {
      final t = _repeating(DateTime(2026, 2, 1));
      expect(scheduledOn(t, DateTime(2026, 1, 31)), isFalse);
      expect(scheduledOn(t, DateTime(2026, 2, 1)), isTrue);
      expect(scheduledOn(t, DateTime(2026, 2, 2)), isTrue);
    });
  });

  group('重复任务的取消语义', () {
    test('关掉重复（isRepeatDaily=false）后回到「只在归属日出现」', () {
      final before = _repeating(DateTime(2026, 1, 10));
      expect(scheduledOn(before, DateTime(2026, 1, 20)), isTrue);
      // 取消重复后的等价对象
      final after = Task(
        id: before.id,
        name: before.name,
        ownerDate: before.ownerDate,
        repeatDaily: false,
        createdAt: before.createdAt,
      );
      expect(scheduledOn(after, DateTime(2026, 1, 10)), isTrue);
      expect(scheduledOn(after, DateTime(2026, 1, 20)), isFalse,
          reason: '取消重复后不再每天出现');
    });
  });

  group('归档不影响历史口径', () {
    test('归档任务：今日不出现、历史出现', () {
      final t = Task(
        id: 9,
        name: '归档了',
        ownerDate: DateTime(2026, 1, 1),
        repeatDaily: true,
        archived: true,
        createdAt: DateTime(2026, 1, 1),
      );
      expect(appearsToday(t, DateTime(2026, 1, 5)), isFalse);
      expect(appearedOnHistory(t, DateTime(2026, 1, 5), doneThatDay: false),
          isTrue);
      expect(scheduledOn(t, DateTime(2026, 1, 5)), isTrue);
    });
  });
}
