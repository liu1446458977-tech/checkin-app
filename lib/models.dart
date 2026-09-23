/// 数据模型：任务、语录。
/// 纯数据类，不依赖 Flutter 运行时，方便单元测试。
library;

import 'dart:convert';
import 'dart:math';

/// 任务形态：**由「每天重复 / 截止日」两个属性派生**，不单独存库，
/// 所以永远不会出现「类型和字段打架」的脏数据。
enum TaskKind {
  single, // 一天的任务：只在归属日出现，第二天不会复制
  repeating, // 重复任务：从归属日起每天都出现
  periodic; // 周期任务：跨天大事，起止日之间每天都出现，完成一次即达成

  String get label => switch (this) {
        TaskKind.single => '临时',
        TaskKind.repeating => '重复',
        TaskKind.periodic => '周期',
      };

  /// 列表里的展示顺序：跨天大事在前，其次每天重复，最后一天的任务
  int get sortOrder => switch (this) {
        TaskKind.periodic => 0,
        TaskKind.repeating => 1,
        TaskKind.single => 2,
      };
}

/// 生成一个 32 位十六进制标识（不引第三方包）。
/// 本地自增 id 只在本机唯一，将来要把「今日完成情况」上传服务器做看板，
/// 三个人的自增 id 一定会撞车，所以每条任务额外带一个稳定标识。
String newTaskUuid() {
  final r = Random.secure();
  return List<int>.generate(16, (_) => r.nextInt(256))
      .map((x) => x.toRadixString(16).padLeft(2, '0'))
      .join();
}

class Task {
  final int? id;
  final String uuid;
  final String name;
  final String note;
  final int colorIndex;

  /// 归属日：这条任务属于哪一天。重复任务 / 周期任务视作起始日。
  final DateTime ownerDate;

  /// 是否每天都出现（新建页的「每天重复」开关，可随时取消）
  final bool repeatDaily;

  /// 截止日：填了就变成「周期任务」，这天之后不再出现
  final DateTime? endDate;

  final bool archived;
  final DateTime createdAt;

  const Task({
    this.id,
    this.uuid = '',
    required this.name,
    this.note = '',
    this.colorIndex = 0,
    required this.ownerDate,
    this.repeatDaily = false,
    this.endDate,
    this.archived = false,
    required this.createdAt,
  });

  TaskKind get kind => repeatDaily
      ? TaskKind.repeating
      : (endDate != null ? TaskKind.periodic : TaskKind.single);
}

/// 一条教员语录或诗词名句
class Quote {
  final String text;
  final String source; // 出处，如《毛泽东选集》《沁园春·雪》

  const Quote(this.text, this.source);
}

/// 睡前总结：一天一条。
/// 四个字段分列存储（而不是拼成一段文本），这样 AI 提示词更准，以后也能做统计。
class DailyNote {
  final String date; // 'YYYY-MM-DD'
  final String gain; // 今天最有收获的一件事
  final String blocker; // 今天遇到的卡点或困难
  final String tomorrow; // 明天最重要的一件事
  final String extra; // 其他想记的
  final int updatedAt;

  const DailyNote({
    required this.date,
    this.gain = '',
    this.blocker = '',
    this.tomorrow = '',
    this.extra = '',
    this.updatedAt = 0,
  });

  bool get isEmpty =>
      gain.trim().isEmpty &&
      blocker.trim().isEmpty &&
      tomorrow.trim().isEmpty &&
      extra.trim().isEmpty;

  bool get isNotEmpty => !isEmpty;

  /// 供 UI 展示的单行摘要
  String get preview {
    for (final s in [gain, blocker, tomorrow, extra]) {
      if (s.trim().isNotEmpty) return s.trim();
    }
    return '';
  }

  int get filledCount =>
      [gain, blocker, tomorrow, extra].where((s) => s.trim().isNotEmpty).length;

  Map<String, Object?> toRow() => {
        'date': date,
        'gain': gain,
        'blocker': blocker,
        'tomorrow': tomorrow,
        'extra': extra,
        'updated_at': updatedAt,
      };

  static DailyNote fromRow(Map<String, Object?> r) => DailyNote(
        date: r['date'] as String,
        gain: (r['gain'] as String?) ?? '',
        blocker: (r['blocker'] as String?) ?? '',
        tomorrow: (r['tomorrow'] as String?) ?? '',
        extra: (r['extra'] as String?) ?? '',
        updatedAt: (r['updated_at'] as int?) ?? 0,
      );
}

/// AI 总结（周 / 半月 / 月）。
/// content 是 Markdown 正文；metrics 是模型额外给出的一行结构化数据（用于画小图表）。
class AiSummary {
  final int? id;
  final String kind; // 对应 PeriodKind.name：week1..week4 / halfFirst / halfSecond / month
  final String periodStart; // 'YYYY-MM-DD'
  final String periodEnd;
  final String periodLabel; // '2026年1月第一周'
  final String content;
  final String metricsJson;
  final String sourceIds; // 逗号分隔的下层总结 id
  final String model;
  final int promptVersion;
  final String status; // 'ok' | 'error'
  final String? error;
  final int createdAt;
  final int updatedAt;

  const AiSummary({
    this.id,
    required this.kind,
    required this.periodStart,
    required this.periodEnd,
    required this.periodLabel,
    this.content = '',
    this.metricsJson = '',
    this.sourceIds = '',
    this.model = '',
    this.promptVersion = 1,
    this.status = 'ok',
    this.error,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  bool get isOk => status == 'ok' && content.trim().isNotEmpty;
  bool get isFailed => status == 'error';

  /// 解析结构化指标；解析失败返回空 Map，绝不抛异常
  Map<String, dynamic> get metrics {
    if (metricsJson.trim().isEmpty) return const {};
    try {
      final v = jsonDecode(metricsJson);
      return v is Map<String, dynamic> ? v : const {};
    } catch (_) {
      return const {};
    }
  }

  List<int> get sourceIdList => sourceIds
      .split(',')
      .map((e) => int.tryParse(e.trim()))
      .whereType<int>()
      .toList();

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'kind': kind,
        'period_start': periodStart,
        'period_end': periodEnd,
        'period_label': periodLabel,
        'content': content,
        'metrics_json': metricsJson,
        'source_ids': sourceIds,
        'model': model,
        'prompt_version': promptVersion,
        'status': status,
        'error': error,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  static AiSummary fromRow(Map<String, Object?> r) => AiSummary(
        id: r['id'] as int?,
        kind: (r['kind'] as String?) ?? '',
        periodStart: (r['period_start'] as String?) ?? '',
        periodEnd: (r['period_end'] as String?) ?? '',
        periodLabel: (r['period_label'] as String?) ?? '',
        content: (r['content'] as String?) ?? '',
        metricsJson: (r['metrics_json'] as String?) ?? '',
        sourceIds: (r['source_ids'] as String?) ?? '',
        model: (r['model'] as String?) ?? '',
        promptVersion: (r['prompt_version'] as int?) ?? 1,
        status: (r['status'] as String?) ?? 'ok',
        error: r['error'] as String?,
        createdAt: (r['created_at'] as int?) ?? 0,
        updatedAt: (r['updated_at'] as int?) ?? 0,
      );
}

/// 重新生成时存档的旧版本
class AiSummaryHistory {
  final int id;
  final int summaryId;
  final String content;
  final String model;
  final int createdAt;

  const AiSummaryHistory({
    required this.id,
    required this.summaryId,
    required this.content,
    required this.model,
    required this.createdAt,
  });

  static AiSummaryHistory fromRow(Map<String, Object?> r) => AiSummaryHistory(
        id: r['id'] as int,
        summaryId: (r['summary_id'] as int?) ?? 0,
        content: (r['content'] as String?) ?? '',
        model: (r['model'] as String?) ?? '',
        createdAt: (r['created_at'] as int?) ?? 0,
      );
}
