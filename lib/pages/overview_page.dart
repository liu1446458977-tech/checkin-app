/// 总览总结：月历热力图 + 本期实时小结 + 已完成记录 + 按日期查阅。
/// 说明：本页的「本期」= 今天所在的「月内固定周」（1-7 / 8-14 / 15-21 / 22-月末），
/// 与后续 AI 周总结的周期口径完全一致。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core_logic.dart';
import '../db.dart';
import '../models.dart';
import '../services/deepseek_client.dart';
import '../services/summary_service.dart';
import '../stats_service.dart';
import 'day_detail_page.dart';
import 'summary_detail_page.dart';

const _kWeekNames = ['一', '二', '三', '四', '五', '六', '日'];

class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key});

  @override
  State<OverviewPage> createState() => OverviewPageState();
}

class OverviewPageState extends State<OverviewPage> {
  DateTime _cursor = DateTime(DateTime.now().year, DateTime.now().month, 1);
  StatsSnapshot? _snap;
  List<CompletionRecord> _records = [];
  Map<String, AiSummary> _summaries = {};
  bool _aiConfigured = false;
  final Set<String> _generating = {};
  bool _loading = true;
  String? _error;

  /// 总结的查找键，与 ai_summaries 的 UNIQUE(kind, period_start) 对应
  String _sKey(Period p) => '${p.kind.name}@${dateKey(p.start)}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 供 HomeShell 在切到本页时调用，避免 IndexedStack 常驻导致数据过期
  Future<void> reload() => _load();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final first = DateTime(_cursor.year, _cursor.month, 1);
      final last = DateTime(_cursor.year, _cursor.month + 1, 0);
      final snap = await loadStats(from: first, to: last);
      final records = completionRecords(snap, from: first, to: last);
      final sums =
          await Db.instance.summariesInRange(dateKey(first), dateKey(last));
      final ai = await AiSettings.load();
      if (!mounted) return;
      setState(() {
        _snap = snap;
        _records = records;
        _summaries = {
          for (final x in sums) '${x.kind}@${x.periodStart}': x
        };
        _aiConfigured = ai.configured;
        _loading = false;
      });
    } catch (e, s) {
      debugPrint('[overview] 加载失败: $e\n$s');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _shiftMonth(int delta) {
    setState(() {
      _cursor = DateTime(_cursor.year, _cursor.month + delta, 1);
    });
    _load();
  }

  void _backToThisMonth() {
    final now = DateTime.now();
    setState(() => _cursor = DateTime(now.year, now.month, 1));
    _load();
  }

  Future<void> _openDay(DateTime d) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DayDetailPage(date: d)),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return LoadErrorView(message: _error!, onRetry: _load);
    }
    if (_loading || _snap == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final snap = _snap!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        _monthHeader(),
        const SizedBox(height: 10),
        _calendarCard(snap),
        const SizedBox(height: 16),
        _currentSegmentCard(snap),
        const SizedBox(height: 16),
        _aiSection(snap),
        const SizedBox(height: 16),
        _recordsCard(),
      ],
    );
  }

  // ---------- 月份切换 ----------

  Widget _monthHeader() {
    final now = DateTime.now();
    final isThisMonth =
        _cursor.year == now.year && _cursor.month == now.month;
    return Row(
      children: [
        IconButton(
          tooltip: '上个月',
          onPressed: () => _shiftMonth(-1),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Center(
            child: Text('${_cursor.year}年${_cursor.month}月',
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700, color: kInk)),
          ),
        ),
        if (!isThisMonth)
          TextButton(onPressed: _backToThisMonth, child: const Text('回到本月'))
        else
          const SizedBox(width: 8),
        IconButton(
          tooltip: '下个月',
          // 不允许翻到未来
          onPressed: isThisMonth ? null : () => _shiftMonth(1),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }

  // ---------- 日历热力图 ----------

  Widget _calendarCard(StatsSnapshot snap) {
    final first = DateTime(_cursor.year, _cursor.month, 1);
    final days = daysInMonth(_cursor.year, _cursor.month);
    final lead = first.weekday - 1; // 周一为 1
    final cells = <Widget>[];
    for (var i = 0; i < lead; i++) {
      cells.add(const SizedBox.shrink());
    }
    for (var day = 1; day <= days; day++) {
      cells.add(_dayCell(datetimeOf(_cursor, day), snap));
    }
    while (cells.length % 7 != 0) {
      cells.add(const SizedBox.shrink());
    }
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += 7) {
      rows.add(Row(
        children: [
          for (var j = 0; j < 7; j++)
            Expanded(child: Padding(
              padding: const EdgeInsets.all(2),
              child: cells[i + j],
            )),
        ],
      ));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          children: [
            Row(
              children: [
                for (final w in _kWeekNames)
                  Expanded(
                    child: Center(
                      child: Text(w,
                          style: const TextStyle(
                              fontSize: 11.5, color: Color(0xFFB3A99C))),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            ...rows,
            const SizedBox(height: 12),
            _legend(),
          ],
        ),
      ),
    );
  }

  Widget _dayCell(DateTime d, StatsSnapshot snap) {
    final s = snap.statAt(d);
    final isToday = dateKey(d) == dateKey(DateTime.now());
    final hasNote = snap.hasNote(d);

    Color bg;
    Color fg;
    if (s.isRest) {
      bg = kRest.withValues(alpha: 0.18);
      fg = kRest;
    } else if (!s.hasData) {
      bg = const Color(0xFFF3EEE6);
      fg = const Color(0xFFB3A99C);
    } else {
      final r = s.ratio;
      bg = kRed.withValues(alpha: 0.10 + 0.80 * r);
      fg = r > 0.55 ? Colors.white : kInk;
    }

    return InkWell(
      onTap: () => _openDay(d),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: isToday ? Border.all(color: kInk, width: 1.4) : null,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (s.isRest)
              Text('休', style: TextStyle(fontSize: 14, color: fg))
            else
              Text('${d.day}', style: TextStyle(fontSize: 13, color: fg)),
            if (hasNote)
              Positioned(
                bottom: 3,
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: s.isRest ? kRest : (s.ratio > 0.55 ? Colors.white : kRed),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _legend() {
    Widget swatch(Color c, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                  color: c, borderRadius: BorderRadius.circular(3)),
            ),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(fontSize: 10.5, color: kMuted)),
          ],
        );
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: [
        swatch(const Color(0xFFF3EEE6), '无记录'),
        swatch(kRed.withValues(alpha: 0.30), '完成少'),
        swatch(kRed.withValues(alpha: 0.65), '完成多'),
        swatch(kRed, '全部完成'),
        swatch(kRest.withValues(alpha: 0.18), '休息日'),
      ],
    );
  }

  // ---------- 本期实时小结（纯本地统计，不调 AI） ----------

  Widget _currentSegmentCard(StatsSnapshot snap) {
    final today = todayOnly(DateTime.now());
    final seg = weekSegmentOf(today);
    final st = snap.statsOf(seg, until: today);
    final done = seg.isFinishedOn(today);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.timelapse_outlined, size: 18, color: kRed),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(seg.fullName,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: kInk)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: done
                        ? const Color(0xFFEDE6DC)
                        : kRed.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(done ? '已结束' : '进行中',
                      style: TextStyle(
                          fontSize: 11.5,
                          color: done ? kMuted : kRed)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(seg.rangeText,
                style: const TextStyle(fontSize: 12, color: kMuted)),
            const SizedBox(height: 14),
            Row(
              children: [
                _bigStat('${st.percent}%', '完成率'),
                _bigStat('${st.perfectDays}', '全部完成天数'),
                _bigStat('${st.restDays}', '休息日'),
                _bigStat('${st.noteDays}', '睡前总结'),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: st.ratio.clamp(0.0, 1.0),
                minHeight: 7,
                backgroundColor: const Color(0xFFEDE6DC),
                color: kRed,
              ),
            ),
            const SizedBox(height: 8),
            Text('累计完成 ${st.doneSlots} / ${st.totalSlots} 项'
                '${st.activeDays > 0 ? ' · 有记录 ${st.activeDays} 天' : ''}',
                style: const TextStyle(fontSize: 12, color: kMuted)),
          ],
        ),
      ),
    );
  }

  Widget _bigStat(String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 19, fontWeight: FontWeight.w700, color: kInk)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(fontSize: 11, color: kMuted)),
        ],
      ),
    );
  }

  // ---------- AI 总结 ----------

  Widget _aiSection(StatsSnapshot snap) {
    final today = todayOnly(DateTime.now());
    final periods = periodsOfMonth(_cursor.year, _cursor.month);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome, size: 18, color: kRed),
                const SizedBox(width: 7),
                const Expanded(
                  child: Text('AI 总结',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: kInk)),
                ),
                if (!_aiConfigured)
                  const Text('未配置 Key',
                      style: TextStyle(fontSize: 11.5, color: Color(0xFFB3A99C))),
              ],
            ),
            const SizedBox(height: 4),
            const Text('周期口径：1-7 / 8-14 / 15-21 / 22-月末，前半月=前两周，整月=两个半月',
                style: TextStyle(fontSize: 11.5, height: 1.5, color: Color(0xFFB3A99C))),
            if (!_aiConfigured)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text('到「设置 → AI 总结」填入 DeepSeek API Key 后即可生成。',
                    style: TextStyle(fontSize: 12.5, color: kRed)),
              ),
            const SizedBox(height: 6),
            for (final p in periods) _aiRow(p, snap, today),
          ],
        ),
      ),
    );
  }

  Widget _aiRow(Period p, StatsSnapshot snap, DateTime today) {
    final summary = _summaries[_sKey(p)];
    final stats = snap.statsOf(p);
    final finished = p.isFinishedOn(today);
    final hasData = stats.activeDays > 0 || stats.noteDays > 0;
    final busy = _generating.contains(_sKey(p));

    String statusText;
    Color statusColor;
    if (busy) {
      statusText = '生成中…';
      statusColor = kRed;
    } else if (summary != null && summary.isOk) {
      statusText = '已生成';
      statusColor = const Color(0xFF6E8B5A);
    } else if (summary != null && summary.isFailed) {
      statusText = '上次失败';
      statusColor = kRed;
    } else if (!finished) {
      statusText = '进行中 · ${p.endText}';
      statusColor = kMuted;
    } else if (!hasData) {
      statusText = '无记录';
      statusColor = const Color(0xFFB3A99C);
    } else {
      statusText = '可生成';
      statusColor = kRed;
    }

    final canTap = summary != null && summary.isOk;
    final canGenerate = _aiConfigured && finished && hasData && !busy;

    return InkWell(
      onTap: canTap
          ? () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => SummaryDetailPage(summary: summary)),
              ).then((_) => _load())
          : null,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.shortName,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: kInk)),
                  const SizedBox(height: 2),
                  Text(
                    canTap
                        ? '${p.rangeText} · ${stats.percent}% · 点击查看'
                        : '${p.rangeText}'
                            '${hasData ? ' · 完成率 ${stats.percent}%' : ''}',
                    style: const TextStyle(fontSize: 11.5, color: kMuted),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(statusText,
                  style: TextStyle(fontSize: 11, color: statusColor)),
            ),
            const SizedBox(width: 4),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(10),
                child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (summary != null && summary.isOk)
              IconButton(
                tooltip: '重新生成',
                onPressed: canGenerate ? () => _generate(p) : null,
                icon: const Icon(Icons.refresh, size: 19),
              )
            else
              TextButton(
                onPressed: canGenerate ? () => _generate(p) : null,
                child: Text(summary != null && summary.isFailed ? '重试' : '生成'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _generate(Period p) async {
    final key = _sKey(p);
    setState(() => _generating.add(key));
    final stage = ValueNotifier<String>('准备中…');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: stage,
                builder: (_, v, _) =>
                    Text(v, style: const TextStyle(fontSize: 14)),
              ),
            ),
          ],
        ),
      ),
    );

    try {
      await SummaryService.generate(p,
          regenerate: true, onStage: (t) => stage.value = t);
      if (mounted) Navigator.pop(context);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${p.shortName} 已生成')));
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      await SummaryService.recordFailure(p, e);
      if (!mounted) return;
      final msg = e is AiException ? e.message : '$e';
      final detail = e is AiException ? e.detail : null;
      final full = detail == null ? msg : '$msg\n\n$detail';
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('生成失败'),
          content: Text(full),
          actions: [
            TextButton(
              // 错误原文一键复制：排查时直接发出来，不用手打
              onPressed: () {
                Clipboard.setData(ClipboardData(text: full));
                Navigator.pop(ctx);
              },
              child: const Text('复制错误信息'),
            ),
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('知道了')),
          ],
        ),
      );
    } finally {
      stage.dispose();
      if (mounted) setState(() => _generating.remove(key));
    }
  }

  // ---------- 已完成记录 ----------

  Widget _recordsCard() {
    if (_records.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: EmptyHint(
            icon: Icons.history_toggle_off_outlined,
            title: '${_cursor.month}月还没有完成记录',
            subtitle: '完成任务后，这里会按日期列出所有已完成项',
          ),
        ),
      );
    }
    // 按日期分组
    final byDate = <String, List<CompletionRecord>>{};
    for (final r in _records) {
      (byDate[dateKey(r.date)] ??= []).add(r);
    }
    final dates = byDate.keys.toList()..sort((a, b) => b.compareTo(a));
    const cap = 40; // 避免一次渲染过多
    final shown = dates.take(cap).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.task_alt, size: 18, color: kRed),
                const SizedBox(width: 7),
                Text('已完成记录（${_records.length}）',
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: kInk)),
              ],
            ),
            const SizedBox(height: 6),
            for (final dateStr in shown) ...[
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 2),
                child: Text(_dateLabel(dateStr),
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: kMuted)),
              ),
              for (final r in byDate[dateStr]!) _recordTile(r),
            ],
            if (dates.length > cap)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('仅显示最近 $cap 天，其余请在日历里按日期查看',
                    style: const TextStyle(fontSize: 11.5, color: Color(0xFFB3A99C))),
              ),
          ],
        ),
      ),
    );
  }

  Widget _recordTile(CompletionRecord r) {
    final t = r.task;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          const Icon(Icons.check_circle, size: 16, color: Color(0xFF9AAE8B)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(t.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: kInk)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFF3EEE6),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(t.kind.label,
                style: const TextStyle(fontSize: 11, color: kMuted)),
          ),
        ],
      ),
    );
  }

  String _dateLabel(String dateStr) {
    final parts = dateStr.split('-');
    if (parts.length != 3) return dateStr;
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (m == null || d == null) return dateStr;
    final dt = DateTime(int.parse(parts[0]), m, d);
    return '$m月$d日 · 星期${_kWeekNames[dt.weekday - 1]}';
  }
}

/// 取某月某天的 DateTime
DateTime datetimeOf(DateTime monthCursor, int day) =>
    DateTime(monthCursor.year, monthCursor.month, day);
