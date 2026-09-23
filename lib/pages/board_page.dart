/// 看板页：看「其他人今天做了多少」。
///
/// 数据来源是服务器 `/api/board`（只读），**不会**改动本地任何数据——
/// 手机永远是唯一数据源，这里只是把服务器上的镜子照出来。
library;

import 'package:flutter/material.dart';

import '../app.dart';
import '../core_logic.dart';
import '../services/board_client.dart';

class BoardPage extends StatefulWidget {
  const BoardPage({super.key});

  @override
  State<BoardPage> createState() => BoardPageState();
}

class BoardPageState extends State<BoardPage> {
  DateTime _date = todayOnly(DateTime.now());
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 供底部导航在切到本页时调用（IndexedStack 常驻，不刷新会看到旧数据）
  Future<void> reload() => _load();

  Future<void> _load({bool silent = false}) async {
    // silent = 下拉刷新：不闪整页加载态，失败也不吃掉已有数据，只弹一条提示
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final cfg = await BoardConfig.load();
      if (!cfg.canView) {
        if (!mounted || silent) return;
        setState(() {
          _loading = false;
          _error = '看板服务器地址为空，请重新安装 App';
        });
        return;
      }
      final data = await BoardClient(cfg).fetchBoard(
        date: dateKey(_date),
        days: 7,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('刷新失败：$e')),
        );
      } else {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  void _shiftDay(int delta) {
    setState(() => _date = _date.add(Duration(days: delta)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    // 这里是底部导航的一个页签：外层壳已经有标题栏、切页也会自动刷新，
    // 所以不再自带 Scaffold/AppBar（否则会叠出两条标题栏）。
    if (_error != null) {
      return LoadErrorView(message: _error!, onRetry: _load);
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        // 内容不满一屏也能下拉刷新
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _dateBar(),
          const SizedBox(height: 4),
          ..._cards(),
          const SizedBox(height: 20),
          _weekGrid(),
        ],
      ),
    );
  }

  Widget _dateBar() {
    final d = _date;
    final isToday = dateKey(d) == dateKey(DateTime.now());
    return Row(
      children: [
        IconButton(
          onPressed: () => _shiftDay(-1),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Center(
            child: Text(
              '${d.year}年${d.month}月${d.day}日'
              ' · 星期${'一二三四五六日'[d.weekday - 1]}${isToday ? ' · 今天' : ''}',
              style: const TextStyle(
                  fontSize: 14.5, fontWeight: FontWeight.w600, color: kInk),
            ),
          ),
        ),
        IconButton(
          onPressed: isToday
              ? null
              : () {
                  setState(() => _date = todayOnly(DateTime.now()));
                  _load();
                },
          icon: const Icon(Icons.today),
        ),
        IconButton(
          onPressed: () => _shiftDay(1),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }

  List<Widget> _cards() {
    final data = _data ?? const {};
    final users = (data['users'] as List?)?.cast<String>() ?? const <String>[];
    final today =
        (data['today'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final byName = {for (final s in today) s['name'] as String: s};

    // 服务器把出现过的昵称都列出来了，所以「今天没上传」的人也要占一张卡，
    // 否则"谁没交"根本看不出来。
    final names = users.isNotEmpty ? users : byName.keys.toList();
    if (names.isEmpty) {
      return [
        const EmptyHint(
          icon: Icons.cloud_off_outlined,
          title: '服务器上还没有任何记录',
          subtitle: '打开「今日」页会自动把当天进度传上去',
        ),
      ];
    }
    return [
      for (final n in names) _userCard(n, byName[n]),
    ];
  }

  Widget _userCard(String name, Map<String, dynamic>? s) {
    final total = (s?['total'] as num?)?.toInt() ?? 0;
    final done = (s?['done'] as num?)?.toInt() ?? 0;
    final isRest = (s?['is_rest'] as bool?) ?? false;
    final streak = (s?['streak'] as num?)?.toInt() ?? 0;
    final tasks =
        (s?['tasks'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final note = s?['note'] as Map<String, dynamic>?;
    final ratio = total == 0 ? (done > 0 ? 1.0 : 0.0) : done / total;
    // 服务器为「今天没上传」的人补的延续卡：只含还在周期内的周期任务
    final carried = s?['carried'] == true;
    final lastSync = s?['last_sync'] as String?;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(name,
                    style: const TextStyle(
                        fontSize: 16.5, fontWeight: FontWeight.w700, color: kInk)),
                const SizedBox(width: 8),
                if (isRest)
                  const Text('休息日',
                      style: TextStyle(fontSize: 12, color: kRest)),
                if (streak > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text('连续 $streak 天',
                        style: const TextStyle(fontSize: 12, color: kMuted)),
                  ),
                if (carried)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Text('未同步',
                        style: TextStyle(fontSize: 12, color: kGold)),
                  ),
              ],
            ),
            if (carried)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '今天还没打开 App（最近同步 ${_shortDate(lastSync)}），'
                  '以下是进行中的周期任务',
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.5, color: kMuted),
                ),
              )
            else ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(s == null ? '—' : '$done',
                      style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: kRed,
                          height: 1)),
                  Text(s == null ? '' : ' / $total',
                      style: const TextStyle(fontSize: 13, color: kMuted)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: s == null ? 0 : ratio,
                        minHeight: 7,
                        backgroundColor: const Color(0xFFEDE6DC),
                        color: isRest ? kRest : kRed,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(s == null ? '' : '${(ratio * 100).round()}%',
                      style: const TextStyle(fontSize: 12, color: kMuted)),
                ],
              ),
            ],
            if (s == null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('这天还没上传', style: TextStyle(fontSize: 13, color: kMuted)),
              )
            else if (tasks.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('这天没有任务', style: TextStyle(fontSize: 13, color: kMuted)),
              )
            else
              for (final t in tasks) _taskRow(t),
            if (note != null && !_noteEmpty(note)) ...[
              const Divider(height: 20, color: Color(0xFFEDE6DC)),
              for (final e in const [
                ('gain', '收获'),
                ('blocker', '卡点'),
                ('tomorrow', '明天'),
                ('extra', '其他'),
              ])
                if ((note[e.$1] as String? ?? '').trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text('${e.$2}：${note[e.$1]}',
                        style: const TextStyle(
                            fontSize: 13, height: 1.5, color: Color(0xFF4B443C))),
                  ),
            ],
          ],
        ),
      ),
    );
  }

  /// '2026-09-19' → '9月19日'（服务器只给 YYYY-MM-DD）
  String _shortDate(String? d) {
    if (d == null || d.length < 10) return '未知';
    final m = int.tryParse(d.substring(5, 7)) ?? 0;
    final day = int.tryParse(d.substring(8, 10)) ?? 0;
    return '$m月$day日';
  }

  bool _noteEmpty(Map<String, dynamic> n) => const ['gain', 'blocker', 'tomorrow', 'extra']
      .every((k) => (n[k] as String? ?? '').trim().isEmpty);

  Widget _taskRow(Map<String, dynamic> t) {
    final done = t['done'] == true;
    final kind = switch (t['kind'] as String? ?? '') {
      'repeating' => '重复',
      'periodic' => '周期',
      _ => '临时',
    };
    final schedule = t['schedule'] as String?;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 17,
              color: done ? const Color(0xFF9AAE8B) : const Color(0xFFC9BFB2)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t['name'] as String? ?? '',
                    style: TextStyle(
                      fontSize: 14,
                      color: done ? kMuted : kInk,
                      decoration: done ? TextDecoration.lineThrough : null,
                    )),
                if (schedule != null && schedule.isNotEmpty)
                  Text(schedule,
                      style: const TextStyle(fontSize: 11.5, color: kMuted)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFF3EEE6),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(kind,
                style: const TextStyle(fontSize: 11, color: kMuted)),
          ),
        ],
      ),
    );
  }

  Widget _weekGrid() {
    final data = _data ?? const {};
    final days = (data['days'] as List?)?.cast<String>() ?? const <String>[];
    final range = (data['range'] as Map?)?.cast<String, dynamic>() ?? const {};
    if (days.isEmpty) return const SizedBox.shrink();
    final users = (data['users'] as List?)?.cast<String>() ?? const <String>[];

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('近 7 天',
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700, color: kInk)),
            const SizedBox(height: 10),
            Table(
              columnWidths: const {0: FlexColumnWidth(1.6)},
              children: [
                TableRow(
                  children: [
                    const SizedBox.shrink(),
                    for (final d in days)
                      Center(
                        child: Text(d.substring(5),
                            style: const TextStyle(fontSize: 11, color: kMuted)),
                      ),
                  ],
                ),
                for (final u in users)
                  TableRow(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Text(u,
                            style: const TextStyle(fontSize: 12.5, color: kMuted)),
                      ),
                      for (final d in days)
                        Center(child: _dayCell(range[d], u)),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dayCell(dynamic dayList, String user) {
    final list = (dayList as List?)?.cast<Map<String, dynamic>>() ?? const [];
    Map<String, dynamic>? s;
    for (final x in list) {
      if (x['name'] == user) {
        s = x;
        break;
      }
    }
    if (s == null) {
      return Container(
        width: 28,
        height: 22,
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F4EF),
          borderRadius: BorderRadius.circular(6),
        ),
      );
    }
    if ((s['is_rest'] as bool?) ?? false) {
      return Container(
        width: 28,
        height: 22,
        margin: const EdgeInsets.all(2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: kRest.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Text('休',
            style: TextStyle(fontSize: 11, color: kRest)),
      );
    }
    final total = (s['total'] as num?)?.toInt() ?? 0;
    final done = (s['done'] as num?)?.toInt() ?? 0;
    final ratio = total == 0 ? (done > 0 ? 1.0 : 0.0) : done / total;
    final color = ratio >= 1
        ? kRed
        : ratio >= 0.66
            ? const Color(0xFFD98C5F)
            : ratio >= 0.33
                ? const Color(0xFFEFC09B)
                : ratio > 0
                    ? const Color(0xFFF6D9C7)
                    : const Color(0xFFF2EDE5);
    return Container(
      width: 28,
      height: 22,
      margin: const EdgeInsets.all(2),
      alignment: Alignment.center,
      decoration:
          BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
      child: Text('${(ratio * 100).round()}',
          style: TextStyle(
              fontSize: 10.5,
              color: ratio >= 0.66 ? Colors.white : const Color(0xFF8A4B2A))),
    );
  }
}
