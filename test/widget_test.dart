/// Widget 层测试：不依赖数据库与平台通道的部分。
/// 覆盖：每日一句的确定性、语录弹窗的渲染与关闭。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkin_app/models.dart';
import 'package:checkin_app/quote_lib.dart';
import 'package:checkin_app/task_actions.dart';

void main() {
  group('dailyQuote', () {
    test('同一天返回同一条（日期做种子）', () {
      final a = dailyQuote(DateTime(2026, 9, 16, 8));
      final b = dailyQuote(DateTime(2026, 9, 16, 23));
      expect(a.text, b.text);
    });

    test('返回语录库中的一条', () {
      final q = dailyQuote(DateTime(2026, 9, 16));
      expect(kQuotes.contains(q), isTrue);
    });
  });

  group('showQuoteSheet', () {
    testWidgets('渲染语录内容，点击「继续前进」关闭', (tester) async {
      const q = Quote('世上无难事，只要肯登攀。', '《水调歌头·重上井冈山》1965');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showQuoteSheet(context, q),
                  child: const Text('打卡'),
                ),
              ),
            ),
          ),
        ),
      );

      // 弹出前：不显示语录
      expect(find.textContaining('世上无难事'), findsNothing);

      await tester.tap(find.text('打卡'));
      await tester.pumpAndSettle();

      expect(find.textContaining('世上无难事'), findsOneWidget);
      expect(find.textContaining('水调歌头'), findsOneWidget);
      expect(find.text('继续前进'), findsOneWidget);

      await tester.tap(find.text('继续前进'));
      await tester.pumpAndSettle();

      expect(find.textContaining('世上无难事'), findsNothing);
    });
  });
}
