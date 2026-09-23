/// AI 总结的编排：资格校验 → 组装上下文 → 调模型 → 解析 → 落库。
/// 全部手动触发（用户点按钮），不做后台自动生成——这样既省调用费，
/// 也避开了 Android 后台被系统杀掉的不可靠性。
library;

import 'package:flutter/foundation.dart';

import '../core_logic.dart';
import '../db.dart';
import '../models.dart';
import '../stats_service.dart';
import 'deepseek_client.dart';
import 'prompts.dart';
import 'secret_store.dart';

// ---------- 设置项 ----------

const String kSecretApiKey = 'deepseek_api_key';
const String kSettingAiModel = 'ai_model';
const String kSettingAiBaseUrl = 'ai_base_url';
const String kSettingAiOnboarded = 'ai_onboarded';

/// AI 相关设置
class AiSettings {
  final String apiKey;
  final String model;
  final String baseUrl;

  const AiSettings({
    this.apiKey = '',
    this.model = DeepSeekClient.kDefaultModel,
    this.baseUrl = DeepSeekClient.kDefaultBaseUrl,
  });

  bool get configured => apiKey.trim().isNotEmpty;

  static Future<AiSettings> load() async {
    final key = await SecretStore.get(kSecretApiKey) ?? '';
    final db = Db.instance;
    final stored = ((await db.getSetting(kSettingAiModel)) ?? '').trim();
    // 旧模型的设置值（deepseek-chat / deepseek-reasoner 等）自动迁移到新默认：
    // 不在可选清单里就用 kDefaultModel，避免"设置里显示的名字根本选不到"
    final model = DeepSeekClient.kModels.contains(stored)
        ? stored
        : DeepSeekClient.kDefaultModel;
    final base =
        await db.getSetting(kSettingAiBaseUrl) ?? DeepSeekClient.kDefaultBaseUrl;
    return AiSettings(apiKey: key, model: model, baseUrl: base);
  }

  DeepSeekClient client({Duration? timeout}) => DeepSeekClient(
        apiKey: apiKey,
        model: model,
        baseUrl: baseUrl,
        // V4-Pro 带思考生成一次可能 2 分钟以上（实测 63~130s），给足余量；
        // 测试连接自己传 45s，不受影响。
        timeout: timeout ?? const Duration(seconds: 300),
      );
}

// ---------- 生成资格 ----------

enum ReadinessStatus { ready, notFinished, noData, noKey, busy }

class GenerateReadiness {
  final ReadinessStatus status;
  final String message;
  final PeriodStats stats;

  const GenerateReadiness(this.status, this.message, this.stats);

  bool get canGenerate => status == ReadinessStatus.ready;
}

// ---------- 服务 ----------

class SummaryService {
  SummaryService._();

  /// 同一周期同时只允许一个生成任务（防止总览页和详情页同时点）
  static final Set<String> _inFlight = <String>{};

  static String lockKey(Period p) => '${p.kind.name}@${dateKey(p.start)}';

  static bool isGenerating(Period p) => _inFlight.contains(lockKey(p));

  /// 检查某周期现在能不能生成。
  /// 规则：周期结束日 <= 今天 且 该周期内有任何记录。
  /// 例：1 月 3 日不能生成「1月第一周」（1 月 7 日才结束），1 月 7 日起可以。
  static Future<GenerateReadiness> check(Period p, {DateTime? today}) async {
    final now = todayOnly(today ?? DateTime.now());
    final snap = await loadStats(from: p.start, to: p.end);
    final stats = snap.statsOf(p);
    if (!p.isFinishedOn(now)) {
      return GenerateReadiness(
        ReadinessStatus.notFinished,
        '该周期还没结束（${p.endText}），结束后才能生成',
        stats,
      );
    }
    if (stats.activeDays == 0 && stats.noteDays == 0) {
      return GenerateReadiness(
        ReadinessStatus.noData,
        '该周期没有任何打卡或睡前总结记录，AI 无从总结',
        stats,
      );
    }
    if (isGenerating(p)) {
      return GenerateReadiness(ReadinessStatus.busy, '正在生成中…', stats);
    }
    final s = await AiSettings.load();
    if (!s.configured) {
      return GenerateReadiness(
        ReadinessStatus.noKey,
        '还没有配置 DeepSeek API Key，请先到「设置 → AI 总结」里填写',
        stats,
      );
    }
    return GenerateReadiness(ReadinessStatus.ready, '可以生成', stats);
  }

  /// 生成（或重新生成）某周期的总结。失败时抛 AiException，由 UI 展示。
  static Future<AiSummary> generate(
    Period p, {
    bool regenerate = false,
    void Function(String stage)? onStage,
  }) async {
    final key = lockKey(p);
    if (_inFlight.contains(key)) {
      throw const AiException(AiErrorKind.badResponse, '该周期正在生成中，请稍候');
    }
    // ⚠️ 顺序不能反：check() 会看「互斥锁」判断是否在生成中。
    // 历史 bug（1.2.0 起）：这里是先 _inFlight.add 再 check —— check 把
    // 「自己刚加的锁」当成别人在生成，于是每次生成都在毫秒级失败、
    // 报「正在生成中…」，AI 总结从未成功过一次。正确顺序：先体检（此时
    // 自己还没进锁），确认能生成后再占锁。
    final ready = await check(p);
    if (!ready.canGenerate) {
      throw AiException(
        ready.status == ReadinessStatus.noKey
            ? AiErrorKind.noKey
            : AiErrorKind.badResponse,
        ready.message,
      );
    }
    // 体检到占锁之间理论上可被并发插入（UI 已禁用按钮，这里再兜一层）
    if (_inFlight.contains(key)) {
      throw const AiException(AiErrorKind.badResponse, '该周期正在生成中，请稍候');
    }
    _inFlight.add(key);
    try {
      final settings = await AiSettings.load();
      final snap = await loadStats(from: p.start, to: p.end);
      final stats = snap.statsOf(p);

      onStage?.call('正在整理数据…');
      final String userPrompt;
      final List<int> sourceIds = [];
      if (p.kind.isLeaf) {
        userPrompt = buildLeafPrompt(
          period: p,
          stats: stats,
          days: await _dayLines(p, snap),
        );
      } else {
        final built = await _rollupSources(p, snap);
        sourceIds.addAll(built.ids);
        userPrompt = buildRollupPrompt(
          period: p,
          stats: stats,
          sources: built.sources,
          restDates: await _restDates(p),
        );
      }

      // 输出额度不额外花钱（按实际生成的 token 计费），设小只会误事：
      // V4 系列默认开思考模式，思考也计入 max_tokens，额度不够会把正文挤没。
      // 统一给足 32000（V4 输出上限 384K；真实一次总结只用 1~4k，没有额外成本）。
      const maxTokens = 32000;
      onStage?.call('正在请求 ${settings.model}…');
      final result = await settings.client().chat(
        systemPrompt: kSystemPrompt,
        userPrompt: userPrompt,
        maxTokens: maxTokens,
        temperature: 0.7,
      );
      if (result.content.trim().isEmpty) {
        // 兜底：额度给足也可能出现「思考吃光输出」
        throw const AiException(
          AiErrorKind.badResponse,
          '模型只输出了思考过程、没有正式内容。'
          '把「设置 → AI 总结 → 选择模型」改成 deepseek-v4-flash 再试即可',
        );
      }

      onStage?.call('正在保存…');
      final split = splitMetrics(result.content);
      final summary = AiSummary(
        kind: p.kind.name,
        periodStart: dateKey(p.start),
        periodEnd: dateKey(p.end),
        periodLabel: p.fullName,
        content: split.content,
        metricsJson: split.metricsJson,
        sourceIds: sourceIds.join(','),
        model: settings.model,
        promptVersion: kPromptVersion,
        status: 'ok',
      );
      final id = await Db.instance.saveSummary(summary);
      debugPrint('[ai] ${p.fullName} 生成成功 '
          '(in=${result.promptTokens} out=${result.completionTokens})');
      return AiSummary.fromRow({...summary.toRow(), 'id': id});
    } finally {
      _inFlight.remove(key);
    }
  }

  /// 记录一次生成失败，让总览页能显示「生成失败 + 原因」
  static Future<void> recordFailure(Period p, Object error) async {
    final existing = await Db.instance.getSummary(p.kind.name, dateKey(p.start));
    if (existing != null && existing.isOk) return; // 已有成功版本就别覆盖
    await Db.instance.saveSummary(AiSummary(
      kind: p.kind.name,
      periodStart: dateKey(p.start),
      periodEnd: dateKey(p.end),
      periodLabel: p.fullName,
      status: 'error',
      error: error is AiException ? error.message : '$error',
    ));
  }

  // ---------- 内部 ----------

  static Future<List<DayLine>> _dayLines(Period p, StatsSnapshot snap) async {
    final notes = <String, DailyNote>{
      for (final n in await Db.instance
          .dailyNotesInRange(dateKey(p.start), dateKey(p.end)))
        n.date: n
    };
    final out = <DayLine>[];
    for (var d = p.start;
        !d.isAfter(p.end);
        d = d.add(const Duration(days: 1))) {
      final st = snap.statAt(d);
      final bd = dayBreakdown(snap, d);
      final note = notes[dateKey(d)];
      out.add(DayLine(
        date: d,
        isRest: st.isRest,
        total: st.total,
        done: st.done,
        doneTasks: bd.done,
        undoneTasks: bd.undone,
        gain: note?.gain ?? '',
        blocker: note?.blocker ?? '',
        tomorrow: note?.tomorrow ?? '',
        extra: note?.extra ?? '',
        hasNote: note != null && note.isNotEmpty,
      ));
    }
    return out;
  }

  static Future<List<String>> _restDates(Period p) async {
    final dates =
        await Db.instance.restDaysInRange(dateKey(p.start), dateKey(p.end));
    final weekdays = await Db.instance.weeklyRestWeekdays();
    final out = <String>[];
    for (var d = p.start;
        !d.isAfter(p.end);
        d = d.add(const Duration(days: 1))) {
      if (isRestDay(d, restDates: dates, weeklyRestWeekdays: weekdays)) {
        out.add(dateKey(d));
      }
    }
    return out;
  }

  /// 取下层来源：优先用已生成的下层总结；缺失的用该段原始数据聚合兜底，
  /// 并在提示词里标注来源，避免 AI 误以为是完整链路。
  static Future<({List<ChildSource> sources, List<int> ids})> _rollupSources(
    Period p,
    StatsSnapshot snap,
  ) async {
    final sources = <ChildSource>[];
    final ids = <int>[];
    for (final child in childPeriods(p)) {
      final saved =
          await Db.instance.getSummary(child.kind.name, dateKey(child.start));
      if (saved != null && saved.isOk) {
        ids.add(saved.id!);
        sources.add(ChildSource(
          label: '${child.fullName}（${child.rangeText}）',
          summaryContent: saved.content,
        ));
      } else {
        sources.add(ChildSource(
          label: '${child.fullName}（${child.rangeText}）',
          fallbackText: await _compactAggregate(child, snap),
        ));
      }
    }
    return (sources: sources, ids: ids);
  }

  /// 缺下层总结时的兜底：紧凑的逐日聚合
  static Future<String> _compactAggregate(Period p, StatsSnapshot snap) async {
    final st = snap.statsOf(p);
    final b = StringBuffer()
      ..writeln('有记录 ${st.activeDays} 天 / 休息日 ${st.restDays} 天 / '
          '应完成 ${st.totalSlots} 项 / 已完成 ${st.doneSlots} 项 / '
          '完成率 ${st.percent}% / 全部完成 ${st.perfectDays} 天 / '
          '睡前总结 ${st.noteDays} 篇')
      ..writeln('逐日：');
    for (var d = p.start;
        !d.isAfter(p.end);
        d = d.add(const Duration(days: 1))) {
      final s = snap.statAt(d);
      if (!s.hasData) continue;
      final bd = dayBreakdown(snap, d);
      b.writeln('${dateKey(d)}${s.isRest ? '[休息日]' : ''} '
          '完成 ${s.done}/${s.total}'
          '${bd.done.isEmpty ? '' : '（已完成：${bd.done.join('、')}）'}'
          '${bd.undone.isEmpty ? '' : '（未完成：${bd.undone.join('、')}）'}');
    }
    // 睡前总结也带上，否则汇总会丢掉最有价值的信息
    final notes = await Db.instance
        .dailyNotesInRange(dateKey(p.start), dateKey(p.end));
    for (final n in notes.where((x) => x.isNotEmpty)) {
      b.writeln('${n.date} 睡前总结：'
          '${[
        if (n.gain.isNotEmpty) '收获 ${n.gain}',
        if (n.blocker.isNotEmpty) '卡点 ${n.blocker}',
        if (n.tomorrow.isNotEmpty) '明天 ${n.tomorrow}',
        if (n.extra.isNotEmpty) '其他 ${n.extra}',
      ].join('；')}');
    }
    return b.toString();
  }
}

/// 从已保存的总结反推它对应的周期（详情页「重新生成」用）
Period periodFromSummary(AiSummary s) {
  final parts = s.periodStart.split('-');
  final y = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? DateTime.now().year) : DateTime.now().year;
  final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 1) : 1;
  final kind = PeriodKind.values.firstWhere(
    (k) => k.name == s.kind,
    orElse: () => PeriodKind.month,
  );
  return periodFor(kind, y, m);
}
