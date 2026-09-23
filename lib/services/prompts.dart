/// AI 提示词构造 + 结构化指标解析。
/// 单独成文件是为了能纯函数单测：提示词里「休息日不批评」「不许编造」这两条
/// 属于产品规则，必须可回归验证。
library;

import 'dart:convert';

import '../core_logic.dart';

/// 提示词版本：改动后旧总结可据此标记为「可重新生成」
const int kPromptVersion = 1;

/// 单条睡前总结字段截断长度，防止 one-shot 请求体过大
const int kNoteFieldLimit = 240;
const int kChildSummaryLimit = 2000;
const int kMaxDayLines = 40;

/// 结构化指标标记
const String kMetricsMarker = '<!--METRICS';

/// 模型被要求额外输出的一行机器可读指标
const String kMetricsInstruction =
    '最后另起一行，输出且只输出这一行（不要放进代码块）：\n'
    '$kMetricsMarker {"completion":0.0,"rest_days":0,"record_days":0,"suggestions":0}-->\n'
    'completion 为本周期完成率(0~1 的小数)，rest_days 为休息日天数，'
    'record_days 为有打卡记录的天数，suggestions 为「下一步方向」里的条数。';

const String kSystemPrompt = '''
你是一位严格但温和的学习教练，帮用户复盘他的打卡记录与睡前总结。

硬性规则：
1. 只依据我提供的数据说话。数据里没有的绝不编造；信息不足就直说「这段记录较少，暂时看不出明显规律」。
2. 【休息日】被标记为休息日的日期，未完成任务属于计划内安排：不得算作不足、不得批评、不得暗示用户偷懒，可以当作「主动恢复」正面提及。
3. 不喊空话、不灌鸡汤。每条建议都要具体可执行，写清做什么、做多久。
4. 语气平实克制，像一个懂行的朋友，不要用感叹号堆砌情绪。

输出格式（严格遵守，使用 Markdown 二级标题）：
## 本周期概况
（3~5 句，客观陈述完成情况与记录情况）
## 做得好的
（2~4 条，每条一句话，尽量引用具体任务名或具体日期）
## 不足
（1~3 条；若确实没有明显问题就写「暂无明显不足」；休息日不算不足）
## 下一步方向
（2~3 条具体建议，指明下一步学什么、怎么调整）

$kMetricsInstruction''';

String _clip(String s, int limit) {
  final t = s.trim();
  if (t.length <= limit) return t;
  return '${t.substring(0, limit)}…';
}

/// 一条逐日明细
class DayLine {
  final DateTime date;
  final bool isRest;
  final int total;
  final int done;
  final List<String> doneTasks;
  final List<String> undoneTasks;
  final String gain;
  final String blocker;
  final String tomorrow;
  final String extra;
  final bool hasNote;

  const DayLine({
    required this.date,
    required this.isRest,
    required this.total,
    required this.done,
    this.doneTasks = const [],
    this.undoneTasks = const [],
    this.gain = '',
    this.blocker = '',
    this.tomorrow = '',
    this.extra = '',
    this.hasNote = false,
  });
}

/// 叶子周期（周）的提示词：直接喂逐日数据
String buildLeafPrompt({
  required Period period,
  required PeriodStats stats,
  required List<DayLine> days,
}) {
  final b = StringBuffer()
    ..writeln('周期：${period.fullName}（${period.rangeText}，共 ${period.totalDays} 天）')
    ..writeln('统计：有记录 ${stats.activeDays} 天 / 休息日 ${stats.restDays} 天 / '
        '应完成 ${stats.totalSlots} 项 / 已完成 ${stats.doneSlots} 项 / '
        '完成率 ${stats.percent}% / 全部完成 ${stats.perfectDays} 天 / '
        '睡前总结 ${stats.noteDays} 篇');

  final restList = days.where((d) => d.isRest).map((d) => dateKey(d.date)).toList();
  if (restList.isNotEmpty) {
    b.writeln('休息日：${restList.join('、')}（这些天未完成属于计划内，不要算作不足）');
  } else {
    b.writeln('休息日：无');
  }

  b.writeln();
  b.writeln('每日明细：');
  final shown = days.length > kMaxDayLines ? days.sublist(0, kMaxDayLines) : days;
  for (final d in shown) {
    final w = const ['一', '二', '三', '四', '五', '六', '日'][d.date.weekday - 1];
    b.writeln('--- ${dateKey(d.date)} 周$w${d.isRest ? ' [休息日]' : ''} ---');
    if (d.total == 0 && d.done == 0) {
      b.writeln('这天没有可打卡的任务');
    } else {
      b.writeln('完成 ${d.done}/${d.total}');
      if (d.doneTasks.isNotEmpty) b.writeln('已完成：${d.doneTasks.join('、')}');
      if (d.undoneTasks.isNotEmpty) b.writeln('未完成：${d.undoneTasks.join('、')}');
    }
    if (d.hasNote) {
      if (d.gain.trim().isNotEmpty) b.writeln('收获：${_clip(d.gain, kNoteFieldLimit)}');
      if (d.blocker.trim().isNotEmpty) b.writeln('卡点：${_clip(d.blocker, kNoteFieldLimit)}');
      if (d.tomorrow.trim().isNotEmpty) b.writeln('明天：${_clip(d.tomorrow, kNoteFieldLimit)}');
      if (d.extra.trim().isNotEmpty) b.writeln('其他：${_clip(d.extra, kNoteFieldLimit)}');
    }
    b.writeln();
  }
  if (days.length > kMaxDayLines) {
    b.writeln('（仅列出前 $kMaxDayLines 天，其余略）');
  }
  return b.toString();
}

/// 汇总周期（半月 / 月）的提示词：喂下层总结，缺失的用原始数据代替并标注
class ChildSource {
  final String label;
  final String? summaryContent; // 有下层总结时为正文
  final String? fallbackText; // 缺总结时用原始聚合数据代替

  const ChildSource({
    required this.label,
    this.summaryContent,
    this.fallbackText,
  });

  bool get fromSummary => summaryContent != null && summaryContent!.trim().isNotEmpty;
}

String buildRollupPrompt({
  required Period period,
  required PeriodStats stats,
  required List<ChildSource> sources,
  required List<String> restDates,
}) {
  final b = StringBuffer()
    ..writeln('周期：${period.fullName}（${period.rangeText}，共 ${period.totalDays} 天）')
    ..writeln('统计：有记录 ${stats.activeDays} 天 / 休息日 ${stats.restDays} 天 / '
        '应完成 ${stats.totalSlots} 项 / 已完成 ${stats.doneSlots} 项 / '
        '完成率 ${stats.percent}% / 全部完成 ${stats.perfectDays} 天 / '
        '睡前总结 ${stats.noteDays} 篇')
    ..writeln(restDates.isEmpty
        ? '休息日：无'
        : '休息日：${restDates.join('、')}（这些天未完成属于计划内，不要算作不足）')
    ..writeln()
    ..writeln('下层总结与数据：');

  for (final s in sources) {
    b.writeln('=== ${s.label}${s.fromSummary ? '' : '（该段没有生成过总结，以下是原始数据汇总）'} ===');
    if (s.fromSummary) {
      b.writeln(_clip(s.summaryContent!, kChildSummaryLimit));
    } else {
      b.writeln(_clip(s.fallbackText ?? '（无数据）', kChildSummaryLimit));
    }
    b.writeln();
  }
  b.writeln('请基于以上内容，生成本周期（${period.shortName}）的总结。层级上它是这些下层内容的归纳，'
      '不要重复罗列细节，重点看趋势、变化和下一步方向。');
  return b.toString();
}

/// 从模型输出里拆出正文与结构化指标。
/// 解析失败时不抛异常，只把 metricsJson 置空——正文永远要保住。
({String content, String metricsJson}) splitMetrics(String raw) {
  final i = raw.lastIndexOf(kMetricsMarker);
  if (i < 0) return (content: raw.trim(), metricsJson: '');
  final j = raw.indexOf('-->', i);
  final content = raw.substring(0, i).trimRight();
  if (j < 0) return (content: content, metricsJson: '');
  final jsonStr = raw.substring(i + kMetricsMarker.length, j).trim();
  try {
    final v = jsonDecode(jsonStr);
    if (v is Map) {
      return (content: content, metricsJson: jsonEncode(v));
    }
  } catch (_) {
    // 模型偶尔会写坏 JSON，忽略即可
  }
  return (content: content, metricsJson: '');
}
