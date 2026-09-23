/// 睡前总结页（替换原「语录」页签）。
/// 一天一条，四个字段分列存储；支持补写历史日期。
/// 保存策略：输入停顿 1.2 秒自动保存 + 明确「保存」按钮 + 切日期前强制落盘，
/// 三重保证不丢字（IndexedStack 常驻，不能只靠 dispose）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../core_logic.dart';
import '../db.dart';
import '../models.dart';
import '../services/board_client.dart';
import '../task_actions.dart';
import '../widgets/daily_note_form.dart';

const _kWeekNames = ['一', '二', '三', '四', '五', '六', '日'];

class SleepSummaryPage extends StatefulWidget {
  const SleepSummaryPage({super.key});

  @override
  State<SleepSummaryPage> createState() => SleepSummaryPageState();
}

class SleepSummaryPageState extends State<SleepSummaryPage>
    with WidgetsBindingObserver {
  final _gainCtrl = TextEditingController();
  final _blockerCtrl = TextEditingController();
  final _tomorrowCtrl = TextEditingController();
  final _extraCtrl = TextEditingController();

  DateTime _date = todayOnly(DateTime.now());
  bool _loading = true;
  bool _dirty = false;
  bool _saving = false;
  DateTime? _savedAt;
  String? _error;
  Timer? _debounce;

  /// 该日完成情况（x/y），与每日任务对齐展示
  int _doneCount = 0;
  int _totalCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  /// 从后台回前台时刷新计数（不动输入框，避免吞掉没保存的字）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) reload();
  }

  /// 供底部导航切到本页时调用（IndexedStack 常驻，不刷新会看到旧数据）。
  /// 只更新「完成 x/y」计数：用户可能正在编辑还没保存的总结，
  /// 跑全量 _load() 会把输入框里没保存的字覆盖掉。
  Future<void> reload() async {
    try {
      final entries = await loadToday(Db.instance, _date, history: !_isToday);
      if (!mounted) return;
      setState(() {
        _doneCount = entries.where((e) => entryDone(e, _date)).length;
        _totalCount = entries.length;
      });
    } catch (e) {
      debugPrint('[sleep] 刷新计数失败: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _gainCtrl.dispose();
    _blockerCtrl.dispose();
    _tomorrowCtrl.dispose();
    _extraCtrl.dispose();
    super.dispose();
  }

  bool get _isToday => dateKey(_date) == dateKey(DateTime.now());

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final note = await Db.instance.getDailyNote(dateKey(_date));
      final entries =
          await loadToday(Db.instance, _date, history: !_isToday);
      final done = entries.where((e) => entryDone(e, _date)).length;
      if (!mounted) return;
      _gainCtrl.text = note?.gain ?? '';
      _blockerCtrl.text = note?.blocker ?? '';
      _tomorrowCtrl.text = note?.tomorrow ?? '';
      _extraCtrl.text = note?.extra ?? '';
      setState(() {
        _loading = false;
        _dirty = false;
        _savedAt = (note != null && note.isNotEmpty && note.updatedAt > 0)
            ? DateTime.fromMillisecondsSinceEpoch(note.updatedAt)
            : null;
        _doneCount = done;
        _totalCount = entries.length;
      });
    } catch (e, s) {
      debugPrint('[sleep] 加载失败: $e\n$s');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _onChanged() {
    if (!_dirty) setState(() => _dirty = true);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1200), _save);
  }

  Future<void> _save() async {
    if (!_dirty || _saving) return;
    _debounce?.cancel();
    setState(() => _saving = true);
    try {
      final note = DailyNote(
        date: dateKey(_date),
        gain: _gainCtrl.text.trim(),
        blocker: _blockerCtrl.text.trim(),
        tomorrow: _tomorrowCtrl.text.trim(),
        extra: _extraCtrl.text.trim(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await Db.instance.saveDailyNote(note);
      // 睡前总结也一起传上去（如果配了服务器）；失败只记日志，不打扰保存流程
      uploadToday(day: _date).ignore();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
        _savedAt = note.isEmpty ? null : DateTime.now();
      });
    } catch (e, s) {
      debugPrint('[sleep] 保存失败: $e\n$s');
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  Future<void> _switchDate(DateTime d) async {
    final target = todayOnly(d);
    if (dateKey(target) == dateKey(_date)) return;
    if (_dirty) await _save(); // 切日期前先落盘，避免丢字
    setState(() => _date = target);
    await _load();
  }

  Future<void> _pickDate() async {
    final today = todayOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(today.year - 3),
      lastDate: today, // 不能给未来写总结
      helpText: '选择要写 / 补写总结的日期',
    );
    if (picked != null) await _switchDate(picked);
  }

  String get _statusText {
    if (_saving) return '保存中…';
    if (_dirty) return '未保存';
    if (_savedAt != null) {
      final t = _savedAt!;
      final hh = t.hour.toString().padLeft(2, '0');
      final mm = t.minute.toString().padLeft(2, '0');
      return '已保存 $hh:$mm';
    }
    return '还没有内容';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return LoadErrorView(message: _error!, onRetry: _load);
    }
    return Column(
      children: [
        _dateBar(),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                _daySummaryBar(),
                const SizedBox(height: 14),
                DailyNoteForm(
                  controllers: [
                    _gainCtrl,
                    _blockerCtrl,
                    _tomorrowCtrl,
                    _extraCtrl,
                  ],
                  onChanged: _onChanged,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(_statusText,
                        style: TextStyle(
                            fontSize: 12.5,
                            color: _dirty ? kRed : kMuted)),
                    const Spacer(),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: kRed),
                      onPressed: _dirty && !_saving ? _save : null,
                      icon: const Icon(Icons.save_outlined, size: 18),
                      label: const Text('保存'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  '写满这几栏，AI 生成周期总结时会准确得多；某一栏不想写就留空。',
                  style: TextStyle(fontSize: 12, color: Color(0xFFB3A99C)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _dateBar() {
    final today = todayOnly(DateTime.now());
    final canForward = _date.isBefore(today);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: '前一天',
            onPressed: () =>
                _switchDate(_date.subtract(const Duration(days: 1))),
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    Text(
                      '${_date.year}年${_date.month}月${_date.day}日',
                      style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: kInk),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '星期${_kWeekNames[_date.weekday - 1]}'
                      '${_isToday ? ' · 今天' : ' · 补写'}',
                      style: const TextStyle(fontSize: 12, color: kMuted),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '后一天',
            onPressed: canForward
                ? () => _switchDate(_date.add(const Duration(days: 1)))
                : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  Widget _daySummaryBar() {
    final ratio = _totalCount == 0 ? 0.0 : _doneCount / _totalCount;
    final allDone = _totalCount > 0 && _doneCount >= _totalCount;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF3EAE2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(allDone ? Icons.verified_outlined : Icons.checklist_outlined,
              size: 20, color: kRed),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _totalCount == 0
                  ? '这天没有需要打卡的任务'
                  : '这天完成了 $_doneCount / $_totalCount 项任务',
              style: const TextStyle(fontSize: 13, color: Color(0xFF7A4A3A)),
            ),
          ),
          if (_totalCount > 0)
            Text('${(ratio * 100).round()}%',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: kRed)),
        ],
      ),
    );
  }
}
