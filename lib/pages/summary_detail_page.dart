/// AI 总结详情页：正文 + 结构化指标 + 来源明细 + 历史版本。
library;

import 'package:flutter/material.dart';

import '../app.dart';
import '../db.dart';
import '../models.dart';
import '../services/deepseek_client.dart';
import '../services/summary_service.dart';

class SummaryDetailPage extends StatefulWidget {
  final AiSummary summary;
  const SummaryDetailPage({super.key, required this.summary});

  @override
  State<SummaryDetailPage> createState() => _SummaryDetailPageState();
}

class _SummaryDetailPageState extends State<SummaryDetailPage> {
  late AiSummary _summary;
  List<AiSummaryHistory> _history = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _summary = widget.summary;
    _load();
  }

  Future<void> _load() async {
    try {
      final fresh = _summary.id == null
          ? null
          : await Db.instance.getSummaryById(_summary.id!);
      final hist = _summary.id == null
          ? <AiSummaryHistory>[]
          : await Db.instance.summaryHistory(_summary.id!);
      if (!mounted) return;
      setState(() {
        if (fresh != null) _summary = fresh;
        _history = hist;
        _loading = false;
      });
    } catch (e, s) {
      debugPrint('[summary] 加载失败: $e\n$s');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _timeText(int ms) {
    if (ms <= 0) return '未知时间';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  Future<void> _regenerate() async {
    final p = periodFromSummary(_summary);
    final stage = ValueNotifier<String>('准备中…');
    // 进度弹窗
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const SizedBox(
                width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: stage,
                builder: (_, v, _) => Text(v, style: const TextStyle(fontSize: 14)),
              ),
            ),
          ],
        ),
      ),
    );

    try {
      final fresh = await SummaryService.generate(p,
          regenerate: true, onStage: (t) => stage.value = t);
      if (!mounted) return;
      Navigator.pop(context); // 关掉进度弹窗
      setState(() => _summary = fresh);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已重新生成')));
    } catch (e) {
      if (mounted) Navigator.pop(context);
      await SummaryService.recordFailure(p, e);
      if (!mounted) return;
      final msg = e is AiException ? e.message : '$e';
      final detail = e is AiException ? e.detail : null;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('生成失败'),
          content: Text(detail == null ? msg : '$msg\n\n$detail'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
          ],
        ),
      );
    } finally {
      stage.dispose();
    }
  }

  Future<void> _restore(AiSummaryHistory h) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复这个版本？'),
        content: Text('将把 ${_timeText(h.createdAt)} 的版本恢复为当前内容，'
            '当前版本会被存档，不会丢。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Db.instance.saveSummary(AiSummary(
      kind: _summary.kind,
      periodStart: _summary.periodStart,
      periodEnd: _summary.periodEnd,
      periodLabel: _summary.periodLabel,
      content: h.content,
      metricsJson: _summary.metricsJson,
      sourceIds: _summary.sourceIds,
      model: h.model,
      promptVersion: _summary.promptVersion,
      status: 'ok',
    ));
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已恢复该版本')));
    }
  }

  Future<void> _openSource(int id) async {
    try {
      final s = await Db.instance.getSummaryById(id);
      if (s == null || !mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => SummaryDetailPage(summary: s)),
      );
    } catch (e) {
      debugPrint('[summary] 打开来源失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _summary.metrics;
    return Scaffold(
      appBar: AppBar(
        title: Text(_summary.periodLabel, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '重新生成',
            onPressed: _regenerate,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                // 结构化指标
                if (m.isNotEmpty) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Row(
                        children: [
                          if (m['completion'] is num)
                            _metric(
                                '${((m['completion'] as num) * 100).round()}%', '完成率'),
                          if (m['record_days'] is num)
                            _metric('${m['record_days']}', '有记录天数'),
                          if (m['rest_days'] is num)
                            _metric('${m['rest_days']}', '休息日'),
                          if (m['suggestions'] is num)
                            _metric('${m['suggestions']}', '建议条数'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // 正文
                ..._renderMarkdown(_summary.content),

                const SizedBox(height: 20),
                const Divider(height: 1, color: Color(0xFFEDE6DC)),
                const SizedBox(height: 12),
                Text(
                  '${_summary.model.isEmpty ? '' : '模型 ${_summary.model} · '}'
                  '生成于 ${_timeText(_summary.updatedAt == 0 ? _summary.createdAt : _summary.updatedAt)}'
                  ' · 提示词 v${_summary.promptVersion}',
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFFB3A99C)),
                ),

                // 来源明细
                if (_summary.sourceIdList.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  const _SectionTitle('本总结的来源'),
                  const SizedBox(height: 4),
                  for (final id in _summary.sourceIdList)
                    _SourceTile(id: id, onTap: () => _openSource(id)),
                ],

                // 历史版本
                if (_history.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  _SectionTitle('历史版本（${_history.length}）'),
                  const SizedBox(height: 4),
                  for (final h in _history)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: const Icon(Icons.history,
                          size: 18, color: Color(0xFF8A837A)),
                      title: Text(_timeText(h.createdAt),
                          style: const TextStyle(fontSize: 13.5)),
                      subtitle: Text(
                        h.content.replaceAll('\n', ' ').trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: kMuted),
                      ),
                      trailing: TextButton(
                        onPressed: () => _restore(h),
                        child: const Text('恢复'),
                      ),
                    ),
                ],
              ],
            ),
    );
  }

  Widget _metric(String value, String label) => Expanded(
        child: Column(
          children: [
            Text(value,
                style: const TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w700, color: kInk)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 11, color: kMuted)),
          ],
        ),
      );

  /// 轻量 Markdown：只处理标题 / 列表 / 加粗，够用且不引依赖
  List<Widget> _renderMarkdown(String src) {
    final out = <Widget>[];
    for (final raw in src.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        out.add(const SizedBox(height: 10));
        continue;
      }
      final t = line.trim();
      if (t.startsWith('### ')) {
        out.add(_heading(t.substring(4), 14.5));
      } else if (t.startsWith('## ')) {
        out.add(_heading(t.substring(3), 16.5));
      } else if (t.startsWith('# ')) {
        out.add(_heading(t.substring(2), 18));
      } else if (t.startsWith('- ') || t.startsWith('* ')) {
        out.add(_bullet(t.substring(2)));
      } else if (RegExp(r'^\d+[.、)]').hasMatch(t)) {
        out.add(_bullet(t));
      } else {
        out.add(Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: _rich(t, const TextStyle(fontSize: 14.5, height: 1.7, color: kInk)),
        ));
      }
    }
    return out;
  }

  Widget _heading(String text, double size) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 8),
        child: Row(
          children: [
            Container(
              width: 3,
              height: size + 4,
              decoration: BoxDecoration(
                color: kRed,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: _rich(text,
                  TextStyle(
                      fontSize: size, fontWeight: FontWeight.w700, color: kInk)),
            ),
          ],
        ),
      );

  Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 7, left: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Icon(Icons.circle, size: 5, color: kRed),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: _rich(text,
                  const TextStyle(fontSize: 14.5, height: 1.65, color: kInk)),
            ),
          ],
        ),
      );

  /// 处理 **加粗**
  Widget _rich(String text, TextStyle base) {
    final parts = text.split('**');
    if (parts.length == 1) return Text(text, style: base);
    final spans = <TextSpan>[];
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      spans.add(TextSpan(
        text: parts[i],
        style: i.isOdd ? const TextStyle(fontWeight: FontWeight.w700) : null,
      ));
    }
    return Text.rich(TextSpan(style: base, children: spans));
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0xFF8A837A),
          letterSpacing: 1));
}

/// 来源条目：按 id 异步取回，避免详情页要先批量加载
class _SourceTile extends StatefulWidget {
  final int id;
  final VoidCallback onTap;
  const _SourceTile({required this.id, required this.onTap});

  @override
  State<_SourceTile> createState() => _SourceTileState();
}

class _SourceTileState extends State<_SourceTile> {
  AiSummary? _s;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await Db.instance.getSummaryById(widget.id);
      if (!mounted) return;
      setState(() {
        _s = s;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: SizedBox(
            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        title: Text('加载中…', style: TextStyle(fontSize: 13)),
      );
    }
    final s = _s;
    if (s == null) {
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.link_off, size: 18, color: Color(0xFFB3A99C)),
        title: Text('来源 #${widget.id}（已删除）',
            style: const TextStyle(fontSize: 13, color: Color(0xFFB3A99C))),
      );
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.subdirectory_arrow_right,
          size: 18, color: Color(0xFF8A837A)),
      title: Text(s.periodLabel, style: const TextStyle(fontSize: 13.5)),
      subtitle: Text(s.content.replaceAll('\n', ' ').trim(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: kMuted)),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: widget.onTap,
    );
  }
}
