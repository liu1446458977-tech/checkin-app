/// 单日详情页：从总览的日历点进来。
/// 展示该日「每日 / 周期 / 临时」任务的完成情况，以及当天的睡前总结（可编辑）。
library;

import 'package:flutter/material.dart';

import '../app.dart';
import '../core_logic.dart';
import '../db.dart';
import '../models.dart';
import '../task_actions.dart';
import '../widgets/daily_note_form.dart';

const _kWeekNames = ['一', '二', '三', '四', '五', '六', '日'];

class DayDetailPage extends StatefulWidget {
  final DateTime date;
  const DayDetailPage({super.key, required this.date});

  @override
  State<DayDetailPage> createState() => _DayDetailPageState();
}

class _DayDetailPageState extends State<DayDetailPage> {
  List<TodayEntry> _entries = [];
  DailyNote? _note;
  bool _isRest = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final key = dateKey(widget.date);
      final entries =
          await loadToday(Db.instance, widget.date, history: true);
      final note = await Db.instance.getDailyNote(key);
      final restDates = await Db.instance.restDaysInRange(key, key);
      final weekdays = await Db.instance.weeklyRestWeekdays();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _note = note;
        _isRest = isRestDay(widget.date,
            restDates: restDates, weeklyRestWeekdays: weekdays);
        _loading = false;
      });
    } catch (e, s) {
      debugPrint('[day] 加载失败: $e\n$s');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  bool _done(TodayEntry e) => entryDone(e, widget.date);

  Future<void> _editNote() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kPaper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _NoteEditSheet(date: widget.date, note: _note),
    );
    if (saved == true) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.date;
    return Scaffold(
      appBar: AppBar(
        title: Text('${d.year}年${d.month}月${d.day}日'),
        actions: [
          IconButton(
            tooltip: '编辑睡前总结',
            onPressed: _editNote,
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
      body: _error != null
          ? LoadErrorView(message: _error!, onRetry: _load)
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                  children: [
                    _headerCard(d),
                    const SizedBox(height: 16),
                    ..._taskSections(),
                    const SizedBox(height: 8),
                    _noteCard(),
                  ],
                ),
    );
  }

  Widget _headerCard(DateTime d) {
    final done = _entries.where(_done).length;
    final total = _entries.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '星期${_kWeekNames[d.weekday - 1]}'
                    '${dateKey(d) == dateKey(DateTime.now()) ? ' · 今天' : ''}',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600, color: kInk),
                  ),
                ),
                if (_isRest)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: kRest.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('休息日',
                        style: TextStyle(fontSize: 12, color: kRest)),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('$done',
                    style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        color: kRed,
                        height: 1)),
                Text(' / $total',
                    style: const TextStyle(fontSize: 15, color: kMuted)),
                const SizedBox(width: 8),
                const Padding(
                  padding: EdgeInsets.only(bottom: 3),
                  child: Text('项任务已完成',
                      style: TextStyle(fontSize: 12.5, color: kMuted)),
                ),
                const Spacer(),
                if (_isRest)
                  const Text('休息日不计入完成率',
                      style: TextStyle(fontSize: 11.5, color: kRest)),
              ],
            ),
            if (total > 0 && !_isRest) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: done / total,
                  minHeight: 7,
                  backgroundColor: const Color(0xFFEDE6DC),
                  color: kRed,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _taskSections() {
    const groups = [
      (TaskKind.periodic, '周期任务', Icons.date_range),
      (TaskKind.repeating, '重复任务', Icons.repeat),
      (TaskKind.single, '临时任务', Icons.bolt),
    ];
    final out = <Widget>[];
    for (final (kind, title, icon) in groups) {
      final list = _entries.where((e) => e.task.kind == kind).toList();
      if (list.isEmpty) continue;
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
        child: Row(
          children: [
            Icon(icon, size: 15, color: kMuted),
            const SizedBox(width: 6),
            Text('$title（${list.where(_done).length}/${list.length}）',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: kMuted,
                    letterSpacing: 0.5)),
          ],
        ),
      ));
      for (final e in list) {
        out.add(_taskTile(e));
      }
    }
    if (out.isEmpty) {
      out.add(const EmptyHint(
        icon: Icons.event_busy_outlined,
        title: '这天没有任务记录',
        subtitle: '任务在创建之前不会出现在历史里',
      ));
    }
    return out;
  }

  Widget _taskTile(TodayEntry e) {
    final done = _done(e);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        dense: true,
        leading: Icon(
          done ? Icons.check_circle : Icons.radio_button_unchecked,
          color: done ? const Color(0xFF9AAE8B) : const Color(0xFFC9BFB2),
        ),
        title: Text(
          e.task.name,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
            color: done ? const Color(0xFF8A837A) : kInk,
            decoration: done ? TextDecoration.lineThrough : null,
          ),
        ),
        trailing: e.task.archived
            ? const Text('已归档',
                style: TextStyle(fontSize: 11.5, color: Color(0xFFB3A99C)))
            : null,
      ),
    );
  }

  Widget _noteCard() {
    final note = _note;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.nightlight_round, size: 17, color: kRed),
                const SizedBox(width: 7),
                const Expanded(
                  child: Text('睡前总结',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: kInk)),
                ),
                TextButton.icon(
                  onPressed: _editNote,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: Text((note != null && note.isNotEmpty) ? '编辑' : '补写'),
                ),
              ],
            ),
            if (note == null || note.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('这天还没有写睡前总结',
                    style: TextStyle(fontSize: 13, color: kMuted)),
              )
            else ...[
              _noteLine(kNoteFieldDefs[0].label, note.gain),
              _noteLine(kNoteFieldDefs[1].label, note.blocker),
              _noteLine(kNoteFieldDefs[2].label, note.tomorrow),
              _noteLine(kNoteFieldDefs[3].label, note.extra),
            ],
          ],
        ),
      ),
    );
  }

  Widget _noteLine(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12, color: Color(0xFFB3A99C))),
          const SizedBox(height: 3),
          Text(value,
              style: const TextStyle(fontSize: 14, height: 1.5, color: kInk)),
        ],
      ),
    );
  }
}

/// 睡前总结编辑弹层（从日期详情页补写/修改）
class _NoteEditSheet extends StatefulWidget {
  final DateTime date;
  final DailyNote? note;
  const _NoteEditSheet({required this.date, this.note});

  @override
  State<_NoteEditSheet> createState() => _NoteEditSheetState();
}

class _NoteEditSheetState extends State<_NoteEditSheet> {
  late final TextEditingController _gain;
  late final TextEditingController _blocker;
  late final TextEditingController _tomorrow;
  late final TextEditingController _extra;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final n = widget.note;
    _gain = TextEditingController(text: n?.gain ?? '');
    _blocker = TextEditingController(text: n?.blocker ?? '');
    _tomorrow = TextEditingController(text: n?.tomorrow ?? '');
    _extra = TextEditingController(text: n?.extra ?? '');
  }

  @override
  void dispose() {
    _gain.dispose();
    _blocker.dispose();
    _tomorrow.dispose();
    _extra.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await Db.instance.saveDailyNote(DailyNote(
        date: dateKey(widget.date),
        gain: _gain.text.trim(),
        blocker: _blocker.text.trim(),
        tomorrow: _tomorrow.text.trim(),
        extra: _extra.text.trim(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e, s) {
      debugPrint('[note] 保存失败: $e\n$s');
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.date;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${d.year}年${d.month}月${d.day}日 · 睡前总结',
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: kInk),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              DailyNoteForm(
                controllers: [_gain, _blocker, _tomorrow, _extra],
                onChanged: () {},
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: kRed, minimumSize: const Size.fromHeight(46)),
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(_saving ? '保存中…' : '保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
