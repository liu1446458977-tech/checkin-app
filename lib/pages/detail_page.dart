/// 任务详情页：查看信息、完成打卡、编辑 / 归档 / 删除。
library;

import 'package:flutter/material.dart';

import '../app.dart';
import '../core_logic.dart';
import '../db.dart';
import '../models.dart';
import '../task_actions.dart';
import 'edit_page.dart';

class DetailPage extends StatefulWidget {
  final TodayEntry entry;
  const DetailPage({super.key, required this.entry});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  Task? _task;
  bool _changed = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final id = widget.entry.task.id!;
      final task = await Db.instance.getTask(id);
      if (task == null) {
        if (mounted) Navigator.pop(context, _changed);
        return;
      }
      if (!mounted) return;
      setState(() {
        _task = task;
        _failed = false;
      });
    } catch (e, s) {
      // 加载失败绝不留下永久转圈。
      debugPrint('[detail] 加载失败: $e\n$s');
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  Future<void> _toggleDone(bool done) async {
    final t = _task!;
    final now = DateTime.now();
    if (done) {
      await completeTask(Db.instance, t.id!, now);
      final q = await giveQuote(Db.instance);
      if (mounted) await showQuoteSheet(context, q);
    } else {
      await uncompleteTask(Db.instance, t.id!, now);
    }
    _changed = true;
    await _load();
  }

  Future<void> _edit() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => EditPage(task: _task)),
    );
    if (result == true) {
      _changed = true;
      await _load();
    }
  }

  Future<void> _archive() async {
    await Db.instance.setArchived(_task!.id!, true);
    _changed = true;
    if (mounted) Navigator.pop(context, _changed);
  }

  /// 删除任务。
  /// 规则（用户定的）：**没打过卡的任务一次确认就删**（手滑打错字 / 任务本身不合理，
  /// 留着碍事）；**已经打过卡的必须两次确认** —— 既防手滑，也覆盖
  /// 「不小心点了打卡却发现删不掉」的场景。
  Future<void> _delete() async {
    final t = _task!;
    final n = await Db.instance.completionCount(t.id!);
    if (!mounted) return;

    final first = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除任务'),
        content: Text(n == 0
            ? '确定删除「${t.name}」吗？'
            : '「${t.name}」已经打过 $n 天卡。\n'
                '删除后这些打卡记录会一起消失，总览里的完成情况和 AI 总结也会跟着变。\n\n'
                '要继续吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kRed),
            onPressed: () => Navigator.pop(context, true),
            child: Text(n == 0 ? '删除' : '继续'),
          ),
        ],
      ),
    );
    if (first != true) return;
    if (!mounted) return;

    // 已打过卡的：再问一次，把代价说清楚（不可恢复）
    if (n > 0) {
      final second = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('再确认一次'),
          content: Text('真的要删掉「${t.name}」和它的 $n 天打卡记录吗？这一步不可恢复。\n\n'
              '如果只是想让它别再出现，建议改用「归档」——历史还留着。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('不删了')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kRed),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认删除'),
            ),
          ],
        ),
      );
      if (second != true) return;
    }

    await Db.instance.deleteTask(t.id!);
    _changed = true;
    if (mounted) Navigator.pop(context, _changed);
  }

  @override
  Widget build(BuildContext context) {
    final t = _task;
    return Scaffold(
      appBar: AppBar(
          title: Text(t?.name ?? '任务详情'),
          actions: [
            if (t != null)
              IconButton(
                tooltip: '编辑',
                icon: const Icon(Icons.edit_outlined),
                onPressed: _edit,
              ),
            if (t != null)
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'archive') _archive();
                  if (v == 'delete') _delete();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'archive', child: Text('归档（保留记录）')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
          ],
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _changed),
          ),
        ),
        body: _failed
            ? LoadErrorView(message: '无法读取任务数据', onRetry: _load)
            : t == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                children: [
                  _TaskMeta(task: t),
                  if (t.note.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const _SectionTitle('备注'),
                    const SizedBox(height: 6),
                    Text(t.note, style: const TextStyle(fontSize: 15, height: 1.6, color: kInk)),
                  ],
                  const SizedBox(height: 28),
                  _DoneButton(
                    task: t,
                    onToggle: _toggleDone,
                  ),
                ],
              ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF8A837A), letterSpacing: 1),
      );
}

class _TaskMeta extends StatelessWidget {
  final Task task;
  const _TaskMeta({required this.task});

  @override
  Widget build(BuildContext context) {
    final rows = <(IconData, String)>[
      (Icons.category_outlined, '类型：${task.kind.label}'),
      (Icons.event_available_outlined, '归属日：${dateKey(task.ownerDate)}'),
      if (task.repeatDaily) (Icons.repeat, '每天重复（可随时取消）'),
      if (task.endDate != null)
        (
          Icons.flag_circle_outlined,
          '周期：${scheduleLabel(task)}'
              '${todayOnly(DateTime.now()).isAfter(todayOnly(task.endDate!)) ? '（已结束）' : ''}'
        ),
      (Icons.schedule, '创建于：${dateKey(task.createdAt)}'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (icon, text) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(icon, size: 16, color: const Color(0xFF8A837A)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(text,
                          style: TextStyle(
                            fontSize: 14,
                            color: kInk,
                          )),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DoneButton extends StatelessWidget {
  final Task task;
  final ValueChanged<bool> onToggle;
  const _DoneButton({
    required this.task,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: kRed),
        onPressed: () => onToggle(true),
        icon: const Icon(Icons.check_circle_outline),
        label: const Text('完成打卡'),
      ),
    );
  }
}
