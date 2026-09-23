/// 休息日设置弹层（入口放在「今日」页签）。
/// 支持两种粒度：指定单个日期、每周固定星期几。
library;

import 'package:flutter/material.dart';

import '../app.dart';
import '../core_logic.dart';
import '../db.dart';

const _kWeekNames = ['一', '二', '三', '四', '五', '六', '日'];

class RestDaySheet extends StatefulWidget {
  /// 任何改动都会回调，调用方据此刷新
  final VoidCallback? onChanged;

  const RestDaySheet({super.key, this.onChanged});

  /// 弹出弹层；返回是否有改动
  static Future<bool> show(BuildContext context, {VoidCallback? onChanged}) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kPaper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => RestDaySheet(onChanged: onChanged),
    );
    return changed ?? false;
  }

  @override
  State<RestDaySheet> createState() => _RestDaySheetState();
}

class _RestDaySheetState extends State<RestDaySheet> {
  Set<String> _restDates = {};
  Set<int> _weekdays = {};
  bool _loading = true;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final dates = await Db.instance.allRestDates();
      final weekdays = await Db.instance.weeklyRestWeekdays();
      if (!mounted) return;
      setState(() {
        _restDates = dates;
        _weekdays = weekdays;
        _loading = false;
      });
    } catch (e, s) {
      debugPrint('[rest] 加载失败: $e\n$s');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  bool _isRest(DateTime d) => isRestDay(d,
      restDates: _restDates, weeklyRestWeekdays: _weekdays);

  Future<void> _toggleDate(DateTime d) async {
    final key = dateKey(d);
    if (_restDates.contains(key)) {
      await Db.instance.removeRestDay(key);
      _restDates.remove(key);
    } else {
      await Db.instance.addRestDay(key);
      _restDates.add(key);
    }
    _changed = true;
    widget.onChanged?.call();
    if (mounted) setState(() {});
  }

  Future<void> _toggleWeekday(int w) async {
    if (_weekdays.contains(w)) {
      _weekdays.remove(w);
    } else {
      _weekdays.add(w);
    }
    await Db.instance.setWeeklyRestWeekdays(_weekdays);
    _changed = true;
    widget.onChanged?.call();
    if (mounted) setState(() {});
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 1),
      helpText: '选择要设为休息日的日期',
    );
    if (picked != null) await _toggleDate(todayOnly(picked));
  }

  @override
  Widget build(BuildContext context) {
    final today = todayOnly(DateTime.now());
    final isTodayRest = _isRest(today);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: _loading
            ? const SizedBox(
                height: 160, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.bedtime_outlined, color: kRest),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text('休息日设置',
                              style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: kInk)),
                        ),
                        IconButton(
                          onPressed: () =>
                              Navigator.pop(context, _changed),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '设为休息日后：不算断签、当晚不提醒、不计入完成率，'
                      'AI 生成总结时也不会因为你没完成任务而批评。',
                      style: TextStyle(
                          fontSize: 12.5, height: 1.6, color: kMuted),
                    ),
                    const SizedBox(height: 16),

                    // 今天
                    Card(
                      child: SwitchListTile(
                        value: isTodayRest,
                        activeThumbColor: kRest,
                        onChanged: (_) => _toggleDate(today),
                        title: Text(
                            '今天（${today.month}月${today.day}日）设为休息日'),
                        subtitle: Text(isTodayRest ? '今天已设为休息日' : '今天照常打卡'),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 指定其他日期
                    OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.event_outlined, size: 18),
                      label: const Text('指定其他日期'),
                    ),
                    const SizedBox(height: 18),

                    // 每周固定
                    const Text('每周固定休息',
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: kInk)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var w = 1; w <= 7; w++)
                          FilterChip(
                            label: Text('周${_kWeekNames[w - 1]}'),
                            selected: _weekdays.contains(w),
                            onSelected: (_) => _toggleWeekday(w),
                            selectedColor: kRest.withValues(alpha: 0.18),
                            checkmarkColor: kRest,
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // 已设置的单日
                    if (_restDates.isNotEmpty) ...[
                      const Text('已指定的休息日',
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: kInk)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final key in (_restDates.toList()..sort()))
                            InputChip(
                              label: Text(key),
                              onDeleted: () async {
                                await Db.instance.removeRestDay(key);
                                _restDates.remove(key);
                                _changed = true;
                                widget.onChanged?.call();
                                if (mounted) setState(() {});
                              },
                              deleteIconColor: kRest,
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
                    Center(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context, _changed),
                        child: const Text('完成'),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
