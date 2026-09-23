/// AI 提示词与结构化指标解析的单元测试。
/// 「休息日不批评」「不许编造」属于产品规则，必须可回归。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:checkin_app/core_logic.dart';
import 'package:checkin_app/services/prompts.dart';

DayLine _day(
  int day, {
  bool rest = false,
  int total = 2,
  int done = 1,
  List<String> doneTasks = const ['背单词'],
  List<String> undoneTasks = const ['跑步'],
  String gain = '',
  String blocker = '',
  bool hasNote = false,
}) =>
    DayLine(
      date: DateTime(2026, 1, day),
      isRest: rest,
      total: total,
      done: done,
      doneTasks: doneTasks,
      undoneTasks: undoneTasks,
      gain: gain,
      blocker: blocker,
      hasNote: hasNote,
    );

void main() {
  group('系统提示词的产品规则', () {
    test('包含休息日不批评的硬性规则', () {
      expect(kSystemPrompt.contains('休息日'), isTrue);
      expect(kSystemPrompt.contains('不得算作不足'), isTrue);
      expect(kSystemPrompt.contains('不得批评'), isTrue);
    });

    test('包含不许编造的规则', () {
      expect(kSystemPrompt.contains('绝不编造'), isTrue);
    });

    test('要求固定四个小标题', () {
      for (final h in ['## 本周期概况', '## 做得好的', '## 不足', '## 下一步方向']) {
        expect(kSystemPrompt.contains(h), isTrue, reason: '缺少 $h');
      }
    });

    test('包含结构化指标要求', () {
      expect(kSystemPrompt.contains(kMetricsMarker), isTrue);
      expect(kSystemPrompt.contains('completion'), isTrue);
    });
  });

  group('叶子周期（周）提示词', () {
    test('列出休息日并明确不要算作不足', () {
      final p = periodFor(PeriodKind.week1, 2026, 1);
      final prompt = buildLeafPrompt(
        period: p,
        stats: const PeriodStats(
          totalDays: 7,
          restDays: 1,
          activeDays: 3,
          totalSlots: 6,
          doneSlots: 4,
          noteDays: 2,
          perfectDays: 1,
        ),
        days: [
          _day(1),
          _day(3, rest: true, done: 0, doneTasks: const [], undoneTasks: const ['跑步']),
        ],
      );
      expect(prompt.contains('2026年1月第一周'), isTrue);
      expect(prompt.contains('2026-01-01 ~ 2026-01-07'), isTrue);
      expect(prompt.contains('休息日：2026-01-03'), isTrue);
      expect(prompt.contains('不要算作不足'), isTrue);
      expect(prompt.contains('[休息日]'), isTrue);
    });

    test('把已完成/未完成与睡前总结写进明细', () {
      final prompt = buildLeafPrompt(
        period: periodFor(PeriodKind.week1, 2026, 1),
        stats: PeriodStats.empty,
        days: [
          _day(1,
              doneTasks: const ['背单词', '跑步'],
              undoneTasks: const ['写代码'],
              gain: '弄懂了指针',
              blocker: '卡在内存管理',
              hasNote: true),
        ],
      );
      expect(prompt.contains('已完成：背单词、跑步'), isTrue);
      expect(prompt.contains('未完成：写代码'), isTrue);
      expect(prompt.contains('收获：弄懂了指针'), isTrue);
      expect(prompt.contains('卡点：卡在内存管理'), isTrue);
    });

    test('超长睡前总结会被截断（防止请求体过大）', () {
      final long = 'x' * 1000;
      final prompt = buildLeafPrompt(
        period: periodFor(PeriodKind.week1, 2026, 1),
        stats: PeriodStats.empty,
        days: [_day(1, gain: long, hasNote: true)],
      );
      expect(prompt.contains('…'), isTrue);
      expect(prompt.length < 1000 + 500, isTrue,
          reason: '正文被截到 kNoteFieldLimit($kNoteFieldLimit)');
    });
  });

  group('汇总周期（半月/月）提示词', () {
    test('来自下层总结时正常引用', () {
      final prompt = buildRollupPrompt(
        period: periodFor(PeriodKind.halfFirst, 2026, 1),
        stats: PeriodStats.empty,
        sources: const [
          ChildSource(label: '2026年1月第一周（2026-01-01 ~ 2026-01-07）', summaryContent: '第一周总结内容'),
        ],
        restDates: const ['2026-01-04'],
      );
      expect(prompt.contains('1月前半月'), isTrue);
      expect(prompt.contains('第一周总结内容'), isTrue);
      expect(prompt.contains('（该段没有生成过总结'), isFalse);
      expect(prompt.contains('休息日：2026-01-04'), isTrue);
    });

    test('缺少下层总结时用原始数据兜底并标注', () {
      final prompt = buildRollupPrompt(
        period: periodFor(PeriodKind.month, 2026, 1),
        stats: PeriodStats.empty,
        sources: const [
          ChildSource(label: '2026年1月前半月', fallbackText: '原始聚合数据'),
        ],
        restDates: const [],
      );
      expect(prompt.contains('该段没有生成过总结，以下是原始数据汇总'), isTrue);
      expect(prompt.contains('原始聚合数据'), isTrue);
      expect(prompt.contains('休息日：无'), isTrue);
    });
  });

  group('结构化指标解析 splitMetrics', () {
    test('正常拆出正文与指标', () {
      const raw = '## 概况\n这周不错\n\n$kMetricsMarker {"completion":0.75,"rest_days":1}-->';
      final r = splitMetrics(raw);
      expect(r.content.contains('这周不错'), isTrue);
      expect(r.content.contains(kMetricsMarker), isFalse, reason: '标记不能留在正文里');
      final m = jsonDecode(r.metricsJson) as Map<String, dynamic>;
      expect(m['completion'], 0.75);
      expect(m['rest_days'], 1);
    });

    test('没有标记时不报错、正文原样保留', () {
      const raw = '## 概况\n普通内容';
      final r = splitMetrics(raw);
      expect(r.content, raw, reason: '没有指标标记时正文原样返回');
      expect(r.metricsJson, '');
    });

    test('标记里 JSON 写坏时只丢弃指标，正文必须保住', () {
      const raw = '正文部分\n\n$kMetricsMarker {completion: 坏掉的}-->';
      final r = splitMetrics(raw);
      expect(r.content, '正文部分');
      expect(r.metricsJson, '');
    });

    test('标记未闭合时也不崩', () {
      const raw = '正文\n\n$kMetricsMarker {"a":1}';
      final r = splitMetrics(raw);
      expect(r.content, '正文');
      expect(r.metricsJson, '');
    });
  });
}
