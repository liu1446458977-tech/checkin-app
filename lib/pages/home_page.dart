import 'package:flutter/material.dart';

import '../app.dart';
import '../core_logic.dart';
import '../db.dart';
import '../models.dart';
import '../reminders.dart';
import '../services/board_client.dart';
import '../task_actions.dart';
import '../widgets/rest_day_sheet.dart';
import 'detail_page.dart';
import 'edit_page.dart';

class TodayPage extends StatefulWidget {
  const TodayPage({super.key});

  @override
  State<TodayPage> createState() => TodayPageState();
}

class TodayPageState extends State<TodayPage> with WidgetsBindingObserver {
  List<TodayEntry>? _entries;
  Quote _todayQuote = const Quote('', '');
  String? _error;
  bool _isRestToday = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _todayQuote = dailyQuote(DateTime.now());
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从后台回前台时刷新：跨过午夜、或在别处改过数据都能自动跟上
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  /// 供 HomeShell 在切到本页时调用（IndexedStack 常驻，不刷新会看到旧数据）
  Future<void> reload() => _reload();

  Future<void> _reload() async {
    try {
      final today = todayOnly(DateTime.now());
      final entries = await loadToday(Db.instance, today);
      // 顺手把「今天还剩几项没完成」推给原生：晚上闹钟响时用它决定发不发、发什么
      pushUndoneCache(Db.instance, today).ignore();
      // 同一时刻把今天的快照推到自己的服务器（没配服务器时这一步直接返回，不影响任何事）
      uploadToday(day: today).ignore();
      final restDates =
          await Db.instance.restDaysInRange(dateKey(today), dateKey(today));
      final weekdays = await Db.instance.weeklyRestWeekdays();
      final isRest = isRestDay(today,
          restDates: restDates, weeklyRestWeekdays: weekdays);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _error = null;
        _isRestToday = isRest;
      });
    } catch (e, s) {
      // 加载失败绝不留下永久转圈：给出提示 + 重试。
      debugPrint('[today] 加载失败: $e\n$s');
      if (!mounted) return;
      setState(() {
        _entries = const [];
        _error = '$e';
      });
    }
  }

  /// 休息日设置入口就在「今日」页签
  Future<void> _openRestSheet() async {
    final changed = await RestDaySheet.show(context);
    if (changed) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 嵌套 Scaffold 只为挂 FAB；背景交给外层，颜色保持一致
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEdit(context, null),
        backgroundColor: kRed,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('新建任务'),
      ),
      body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            todayQuote: _todayQuote,
            entries: _entries ?? const [],
            isRest: _isRestToday,
            onRestTap: _openRestSheet,
          ),
          const SizedBox(height: 4),
          if (_isRestToday) _RestBanner(date: todayOnly(DateTime.now())),
          _QuoteBar(quote: _todayQuote),
          Expanded(
            child: _entries == null
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? LoadErrorView(message: _error!, onRetry: _reload)
                    : _entries!.isEmpty
                        ? const _EmptyGuide()
                        : _TaskList(
                            entries: _entries!,
                            onChanged: _reload,
                            onOpen: (t) => _openDetail(context, t),
                            onQuick: _quickActions,
                          ),
          ),
        ],
      ),
      ),
    );
  }

  Future<void> _openEdit(BuildContext context, Task? task) async {
    // 返回后无条件刷新：系统返回键不带 result，只认返回值会漏刷新
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => EditPage(task: task)),
    );
    await _reload();
  }

  /// 长按任务卡片的快捷操作：编辑 / 归档 / 删除
  Future<void> _quickActions(TodayEntry e) async {
    final t = e.task;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kPaper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(t.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: kInk)),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑任务'),
              subtitle: const Text('改名称、日期、重复等'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('归档'),
              subtitle: const Text('不再出现在今日，但保留历史打卡记录'),
              onTap: () => Navigator.pop(ctx, 'archive'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: kRed),
              title: const Text('删除任务', style: TextStyle(color: kRed)),
              subtitle: const Text('打卡记录会一并删除，不可恢复'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'edit') {
      await _openEdit(context, t);
      return;
    }
    if (action == 'archive') {
      await Db.instance.setArchived(t.id!, true);
      await _reload();
      return;
    }
    if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('删除任务'),
          content: Text('确定删除「${t.name}」吗？相关打卡记录也会一并删除，且不可恢复。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kRed),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (ok == true) {
        await Db.instance.deleteTask(t.id!);
        await _reload();
      }
    }
  }

  Future<void> _openDetail(BuildContext context, TodayEntry e) async {
    // 返回后无条件刷新：详情页里打卡/改任务后（含系统返回键），列表要立刻跟上
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => DetailPage(entry: e)),
    );
    await _reload();
  }
}

class _Header extends StatelessWidget {
  final Quote todayQuote;
  final List<TodayEntry> entries;
  final bool isRest;
  final VoidCallback onRestTap;
  const _Header({
    required this.todayQuote,
    required this.entries,
    required this.isRest,
    required this.onRestTap,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final hour = now.hour;
    final greet = hour < 6
        ? '夜深了，同志'
        : hour < 12
            ? '早上好，同志'
            : hour < 18
                ? '下午好，同志'
                : '晚上好，同志';
    const week = ['一', '二', '三', '四', '五', '六', '日'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(greet,
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: kInk)),
                const SizedBox(height: 4),
                Text(
                  '${now.year}年${now.month}月${now.day}日 · 星期${week[now.weekday - 1]}',
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF8A837A), letterSpacing: 1),
                ),
              ],
            ),
          ),
          _ProgressRing(entries: entries, quote: todayQuote),
          IconButton(
            tooltip: isRest ? '今天是休息日（点击修改）' : '设置休息日',
            onPressed: onRestTap,
            icon: Icon(
              isRest ? Icons.bedtime : Icons.bedtime_outlined,
              color: isRest ? kRest : kMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// 休息日横幅：任务照常列出，但当天不计入完成率、不算断签、也不会被提醒。
class _RestBanner extends StatelessWidget {
  final DateTime date;
  const _RestBanner({required this.date});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: kRest.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.bedtime, size: 18, color: kRest),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '今天是休息日：不算断签、今晚不提醒，AI 总结也不会因此批评你。',
                style: const TextStyle(fontSize: 12.5, height: 1.4, color: kRest),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 头部进度环：显示今日完成进度
class _ProgressRing extends StatelessWidget {
  final List<TodayEntry> entries;
  final Quote quote;
  const _ProgressRing({required this.entries, required this.quote});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final now = DateTime.now();
    final done = entries.where((e) => entryDone(e, now)).length;
    final pct = done / entries.length;
    return Stack(
      alignment: Alignment.center,
      children: [
        SizedBox(
          width: 46,
          height: 46,
          child: CircularProgressIndicator(
            value: pct,
            strokeWidth: 5,
            backgroundColor: const Color(0xFFEDE6DC),
            color: kRed,
          ),
        ),
        Text('$done/${entries.length}',
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: kInk)),
      ],
    );
  }
}

class _QuoteBar extends StatelessWidget {
  final Quote quote;
  const _QuoteBar({required this.quote});

  @override
  Widget build(BuildContext context) {
    if (quote.text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF3EAE2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '今日一勉 · “${quote.text}”',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontSize: 13, color: Color(0xFF7A4A3A), height: 1.4),
        ),
      ),
    );
  }
}

class _EmptyGuide extends StatelessWidget {
  const _EmptyGuide();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.flag_outlined, size: 48, color: Color(0xFFC9BFB2)),
          SizedBox(height: 12),
          Text('今天还没有任务',
              style: TextStyle(color: Color(0xFF8A837A), fontSize: 15)),
          SizedBox(height: 4),
          Text('点右下角的「新建任务」开始',
              style: TextStyle(color: Color(0xFFB3A99C), fontSize: 13)),
        ],
      ),
    );
  }
}

class _TaskList extends StatelessWidget {
  final List<TodayEntry> entries;
  final VoidCallback onChanged;
  final ValueChanged<TodayEntry> onOpen;
  final ValueChanged<TodayEntry> onQuick;

  const _TaskList({
    required this.entries,
    required this.onChanged,
    required this.onOpen,
    required this.onQuick,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final done = entries.where((e) => entryDone(e, now)).length;
    final groups = <(String, List<TodayEntry>)>[
      ('周期任务', entries.where((e) => e.task.kind == TaskKind.periodic).toList()),
      ('重复任务', entries.where((e) => e.task.kind == TaskKind.repeating).toList()),
      ('临时任务', entries.where((e) => e.task.kind == TaskKind.single).toList()),
    ];
    return RefreshIndicator(
      onRefresh: () async => onChanged(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _todaySummary(done, entries.length),
          const SizedBox(height: 8),
          for (final (title, list) in groups)
            if (list.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A837A),
                        letterSpacing: 1)),
              ),
              for (final e in list)
                _TaskCard(
                  entry: e,
                  onChanged: onChanged,
                  onOpen: onOpen,
                  onQuick: onQuick,
                ),
            ],
        ],
      ),
    );
  }

  Widget _todaySummary(int done, int total) {
    if (total == 0) return const SizedBox.shrink();
    final pct = total == 0 ? 0.0 : done / total;
    return Row(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 52,
              height: 52,
              child: CircularProgressIndicator(
                value: pct,
                strokeWidth: 5,
                backgroundColor: const Color(0xFFEDE6DC),
                color: kRed,
              ),
            ),
            Text('$done/$total',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: kInk)),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('今日进度',
                  style: TextStyle(
                      fontSize: 13, color: Color(0xFF8A837A), letterSpacing: 1)),
              const SizedBox(height: 2),
              Text(
                done == total && total > 0 ? '今日任务全部完成，好样的！' : pct < 0.5 ? '万里长征，刚起步。' : '行百里者半九十，继续。',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: kInk),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TaskCard extends StatelessWidget {
  final TodayEntry entry;
  final VoidCallback onChanged;
  final ValueChanged<TodayEntry> onOpen;
  final ValueChanged<TodayEntry> onQuick;

  const _TaskCard({
    required this.entry,
    required this.onChanged,
    required this.onOpen,
    required this.onQuick,
  });

  @override
  Widget build(BuildContext context) {
    final t = entry.task;
    final now = DateTime.now();
    final done = entryDone(entry, now);

    final subtitle = StringBuffer();
    if (t.kind == TaskKind.periodic) {
      // 周期任务必须让人看清「这是哪一段周期」
      subtitle.write(scheduleLabel(t));
      if (todayOnly(now).isAfter(todayOnly(t.endDate!))) {
        subtitle.write('（已结束）');
      }
    } else if (t.repeatDaily) {
      subtitle.write('每天重复 · 自 ${scheduleLabel(t)}');
    }
    final schedule = subtitle.toString();
    // 备注直接摊在任务条里（小字），不用点进详情就能看到
    final note = t.note.trim();

    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: done
              ? const Color(0xFFE8E3DA)
              : kRed.withValues(alpha: 0.10),
          child: Icon(
            switch (t.kind) {
              TaskKind.periodic => Icons.date_range,
              TaskKind.repeating => Icons.repeat,
              TaskKind.single => Icons.bolt,
            },
            size: 18,
            color: done ? const Color(0xFFB3A99C) : kRed,
          ),
        ),
        title: Text(
          t.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: done ? const Color(0xFFB3A99C) : kInk,
            decoration: done ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: (schedule.isEmpty && note.isEmpty)
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (schedule.isNotEmpty)
                    Text(schedule,
                        style: TextStyle(
                            fontSize: 12,
                            color: done
                                ? const Color(0xFFC9BFB2)
                                : const Color(0xFF8A837A))),
                  if (note.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: schedule.isEmpty ? 0 : 2),
                      child: Text(
                        note,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: done
                                ? const Color(0xFFC9BFB2)
                                : const Color(0xFF9A8F80)),
                      ),
                    ),
                ],
              ),
        trailing: done
            ? const Icon(Icons.check_circle, color: Color(0xFFB3A99C))
            : IconButton(
                icon: const Icon(Icons.check_circle_outline, color: kRed),
                tooltip: '完成打卡',
                onPressed: () async {
                  await completeTask(Db.instance, t.id!, now);
                  final q = await giveQuote(Db.instance);
                  if (context.mounted) await showQuoteSheet(context, q);
                  onChanged();
                }),
        // 整块卡片都可点开详情页（编辑 / 归档 / 删除都在那里）
        onTap: () => onOpen(entry),
        onLongPress: () => onQuick(entry),
      ),
    );
  }
}
