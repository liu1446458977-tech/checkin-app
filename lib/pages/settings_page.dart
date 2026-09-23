/// 设置页：提醒时间、通知开关、打卡统计、关于。
library;

import 'package:flutter/material.dart';

import '../app.dart';
import '../core_logic.dart';
import '../db.dart';
import '../reminders.dart';
import '../services/board_client.dart';
import '../services/deepseek_client.dart';
import '../services/export_service.dart';
import '../services/profile.dart';
import '../services/secret_store.dart';
import '../services/summary_service.dart';
import '../stats_service.dart';
import 'onboarding_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _remindHour = 22;
  bool _enabled = true;
  bool _loaded = false;
  String? _error;
  int _totalTasks = 0;
  String _userName = '';
  bool _boardEnabled = false;
  int _archivedTasks = 0;
  int _streak = 0;
  int _todayDone = 0;
  int _todayTotal = 0;
  bool _isRestToday = false;
  bool _exporting = false;

  // AI 相关
  bool _aiConfigured = false;
  String _aiModel = DeepSeekClient.kDefaultModel;
  String _aiBackend = '';
  bool _testingAi = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _loadInner();
    } catch (e, s) {
      // 加载失败绝不留下永久转圈：给出提示 + 重试。
      debugPrint('[settings] 加载失败: $e\n$s');
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loaded = true;
      });
    }
  }

  Future<void> _loadInner() async {
    final db = Db.instance;
    final hour =
        int.tryParse((await db.getSetting(kSettingRemindHour)) ?? '') ?? 22;
    final enabled = (await db.getSetting(kSettingRemindEnabled)) ?? '1';
    final now = todayOnly(DateTime.now());

    // AI 设置
    final ai = await AiSettings.load();
    final backend = await SecretStore.backendLabel();
    final name = await userName();
    final board = await BoardConfig.load();

    // 一次取回统计所需数据（含回溯 400 天，供连续达标使用）
    final snap = await loadStats(from: now, to: now);
    final today = snap.statAt(now);
    final active = snap.tasks.where((t) => !t.archived).toList();

    if (!mounted) return;
    setState(() {
      _remindHour = hour;
      _enabled = enabled == '1';
      _userName = name.isEmpty ? '未设置' : name;
      _boardEnabled = board.enabled;
      _totalTasks = active.length;
      _archivedTasks = snap.tasks.length - active.length;
      // 完成数可能因「已归档任务的历史打卡」略大于应完成数，展示时收敛
      _todayDone = today.done > today.total ? today.total : today.done;
      _todayTotal = today.total;
      // 连续达标：休息日既不断签、也不计入（见 core_logic.calcStreak）
      _streak = snap.streak(now);
      _isRestToday = today.isRest;
      _aiConfigured = ai.configured;
      _aiModel = ai.model;
      _aiBackend = backend;
      _error = null;
      _loaded = true;
    });
  }

  Future<void> _setHour(int hour) async {
    await Db.instance.setSetting(kSettingRemindHour, '$hour');
    setState(() => _remindHour = hour);
    // 立刻把新时间排给原生闹钟（原生每次都先撤销再排，幂等）
    await syncReminderSchedule(hour: hour, enabled: _enabled);
  }

  Future<void> _setEnabled(bool v) async {
    await Db.instance.setSetting(kSettingRemindEnabled, v ? '1' : '0');
    setState(() => _enabled = v);
    if (v) {
      // Android 13+ 要动态申请通知权限，否则提醒是"哑"的
      final ok = await requestNotificationPermission();
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('还没拿到通知权限：请在系统弹窗里选「允许」，'
                '或到系统设置 → 应用 → 通知 里手动打开')));
      }
    }
    await syncReminderSchedule(hour: _remindHour, enabled: v);
  }

  Future<void> _pickHour() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _remindHour, minute: 0),
      initialEntryMode: TimePickerEntryMode.input,
    );
    if (picked == null) return;
    await _setHour(picked.hour);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('提醒时间已设为每天 ${_two(picked.hour)}:00')),
      );
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  // ---------- AI 设置 ----------

  Future<void> _editApiKey() async {
    final existing = await SecretStore.get(kSecretApiKey);
    if (!mounted) return; // 跨 await 用 context 前必须确认还挂载着
    final ctrl = TextEditingController(text: existing ?? '');
    var obscure = true;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('DeepSeek API Key'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: ctrl,
                obscureText: obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  hintText: 'sk-...',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                        obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setDlg(() => obscure = !obscure),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text('存储方式：$_aiBackend',
                  style: const TextStyle(fontSize: 12, color: kMuted)),
              const SizedBox(height: 6),
              const Text(
                '申请地址 platform.deepseek.com → API keys；'
                '建议单独申请一个 Key 并设置消费上限。',
                style: TextStyle(fontSize: 11.5, height: 1.5, color: Color(0xFFB3A99C)),
              ),
            ],
          ),
          actions: [
            if (existing != null && existing.isNotEmpty)
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'clear'),
                child: const Text('清除', style: TextStyle(color: kRed)),
              ),
            TextButton(
                onPressed: () => Navigator.pop(ctx, 'cancel'),
                child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kRed),
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (action == 'clear') {
      await SecretStore.delete(kSecretApiKey);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已清除 API Key')));
      await _load();
      return;
    }
    if (action != 'save') return;
    final key = ctrl.text.trim();
    if (key.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Key 不能为空')));
      return;
    }
    await SecretStore.put(kSecretApiKey, key);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已保存')));
    await _load();
  }

  Future<void> _editModel() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择模型'),
        children: [
          // Flutter 3.32+ 用 RadioGroup 统一管理选中值（RadioListTile 的
          // groupValue/onChanged 已废弃）
          RadioGroup<String>(
            groupValue: _aiModel,
            onChanged: (v) {
              if (v != null) Navigator.pop(ctx, v);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final m in DeepSeekClient.kModels)
                  RadioListTile<String>(
                    value: m,
                    title: Text(m),
                    subtitle: Text(m == 'deepseek-v4-flash'
                        ? '快、便宜，日常总结够用（推荐）'
                        : '更强，更慢也更贵'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await Db.instance.setSetting(kSettingAiModel, picked);
    if (!mounted) return;
    await _load();
  }

  Future<void> _testAi() async {
    setState(() => _testingAi = true);
    try {
      final ai = await AiSettings.load();
      if (!ai.configured) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('请先填写 API Key')));
        return;
      }
      final reply =
          await ai.client(timeout: const Duration(seconds: 45)).testConnection();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接正常（模型回复：${reply.isEmpty ? '空' : reply}）')));
    } catch (e) {
      if (!mounted) return;
      final msg = e is AiException ? e.message : '$e';
      final detail = e is AiException ? e.detail : null;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('连接失败'),
          content: Text(detail == null ? msg : '$msg\n\n$detail'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('知道了')),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _testingAi = false);
    }
  }

  Future<void> _export({required bool asJson}) async {
    setState(() => _exporting = true);
    try {
      final uri = asJson
          ? await ExportService.exportJson()
          : await ExportService.exportCsv();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(uri == null ? '已取消导出' : '已导出到：$uri'),
      ));
    } catch (e, s) {
      debugPrint('[export] 失败: $e\n$s');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导出失败：$e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 昵称重置（**隐藏入口**：长按「昵称」那一行）。
  /// 「设置后不可修改」是硬规则——它是身份标识，不能让日常操作随手改掉；
  /// 但打错字总得有条路，所以留一个需要特意长按才会触发的重置。
  Future<void> _resetUserName() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置昵称'),
        content: const Text('昵称是身份标识（以后联云看板按它区分每个人），'
            '正常情况下不需要改。\n\n'
            '只有打错字时才用它：重置后要重新设置一次；看板上你的历史数据'
            '会一起迁到新名字下，不会丢。\n\n'
            '确定重置吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 记下老昵称：重新设置后由 App 自动把服务器上的老数据迁到新昵称名下，
    // 避免看板上出现「同一个人两张卡」和旧昵称残留
    final oldName = await userName();
    if (oldName.isNotEmpty) {
      await Db.instance.setSetting(kSettingPendingRenameFrom, oldName);
    }
    await Db.instance.setSetting(kSettingUserName, '');
    if (!mounted) return;
    // 立刻走一遍引导页把昵称补回来，不用重启 App
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (ctx) => OnboardingPage(onDone: () => Navigator.pop(ctx)),
      ),
    );
    if (!mounted) return;
    setState(() => _loaded = false);
    _load();
  }

  // ---------- 看板 ----------

  Future<void> _setBoardEnabled(bool v) async {
    await BoardConfig.save(enabled: v);
    setState(() => _boardEnabled = v);
    // 打开开关就立刻补传一次，省得等下次打卡才在别人的看板上出现
    if (v) uploadToday().ignore();
  }

  /// 发一条测试提醒：顺便把通知权限的问题当场暴露出来
  Future<void> _testNotification() async {
    final ok = await requestNotificationPermission();
    await showTestNotification();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('还没拿到通知权限：请在系统弹窗里选「允许」，'
              '或到系统设置 → 应用 → 通知 里手动打开')));
      return;
    }
    final ready = await notificationReady();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ready ? '已发送测试提醒，看到通知就说明没问题' : '通知被系统关掉了，请到系统设置里开启'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return SafeArea(
        child: LoadErrorView(
          message: _error!,
          onRetry: () {
            setState(() => _loaded = false);
            _load();
          },
        ),
      );
    }
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
        children: [
          const Text('设置',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: kInk)),
          const SizedBox(height: 16),
          _StatCard(
            todayDone: _todayDone,
            todayTotal: _todayTotal,
            streak: _streak,
            totalTasks: _totalTasks,
            archivedTasks: _archivedTasks,
          ),
          if (_isRestToday)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text('今天是休息日：不算断签、今晚不提醒，AI 总结也不会因此批评你。',
                  style: TextStyle(fontSize: 12.5, color: kRest)),
            ),
          const SizedBox(height: 20),
          const _Section('身份'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.badge_outlined, color: kRed),
              title: const Text('昵称'),
              // 长按这一行可以重置昵称——故意不留任何文字提示，只有作者知道
              onLongPress: _resetUserName,
              trailing: Text(_userName,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600, color: kInk)),
            ),
          ),
          const SizedBox(height: 20),
          const _Section('提醒'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  value: _enabled,
                  activeThumbColor: kRed,
                  onChanged: _setEnabled,
                  title: const Text('每晚检查提醒'),
                  subtitle: const Text('到点若还有未完成任务才提醒，全部完成不打扰'),
                ),
                const Divider(height: 1, color: Color(0xFFEDE6DC)),
                ListTile(
                  enabled: _enabled,
                  leading: const Icon(Icons.alarm, color: kRed),
                  title: const Text('提醒时间'),
                  subtitle: const Text('每天到点由系统闹钟唤醒，App 不用在后台运行'),
                  trailing: Text('${_two(_remindHour)}:00',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600, color: kInk)),
                  onTap: _enabled ? _pickHour : null,
                ),
                const Divider(height: 1, color: Color(0xFFEDE6DC)),
                ListTile(
                  leading: const Icon(Icons.notifications_active_outlined,
                      color: Color(0xFF8A837A)),
                  title: const Text('发送测试提醒'),
                  subtitle: const Text('确认通知权限没问题（不用等到晚上）'),
                  onTap: _testNotification,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _Section('看板'),
          Card(
            // 整节只留这一个开关：服务器地址内置、每天自动上传，终端用户零配置。
            // 服务器地址/口令不再暴露到界面上（改地址=重新出包，避免误改）。
            child: SwitchListTile(
              value: _boardEnabled,
              activeThumbColor: kRed,
              onChanged: _setBoardEnabled,
              title: const Text('自动上传今日进度'),
            ),
          ),
          const SizedBox(height: 20),
          const _Section('AI 总结'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    _aiConfigured ? Icons.key : Icons.key_off_outlined,
                    color: _aiConfigured ? const Color(0xFF6E8B5A) : kRed,
                  ),
                  title: const Text('DeepSeek API Key'),
                  subtitle: Text(_aiConfigured
                      ? '已配置 · 存储方式：$_aiBackend'
                      : '未配置（不影响打卡、睡前总结和总览）'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _editApiKey,
                ),
                const Divider(height: 1, color: Color(0xFFEDE6DC)),
                ListTile(
                  leading: const Icon(Icons.memory, color: Color(0xFF8A837A)),
                  title: const Text('模型'),
                  subtitle: Text(_aiModel),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _editModel,
                ),
                const Divider(height: 1, color: Color(0xFFEDE6DC)),
                ListTile(
                  leading: const Icon(Icons.wifi_tethering,
                      color: Color(0xFF8A837A)),
                  title: const Text('测试连接'),
                  subtitle: const Text('发一条极短请求，确认 Key 与网络可用'),
                  trailing: _testingAi
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.chevron_right),
                  enabled: !_testingAi,
                  onTap: _testAi,
                ),
                const Divider(height: 1, color: Color(0xFFEDE6DC)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                  child: Text(
                    '生成总结时你选中的周期的打卡记录与睡前总结原文会发送给 DeepSeek。'
                    '周期全部手动生成，不会在后台自动调用。',
                    style: TextStyle(
                        fontSize: 11.5, height: 1.6, color: Color(0xFFB3A99C)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _Section('数据'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.backup_outlined, color: kRed),
                  title: const Text('导出完整备份（JSON）'),
                  subtitle: const Text('任务、打卡、睡前总结、休息日等全部数据'),
                  trailing: const Icon(Icons.chevron_right),
                  enabled: !_exporting,
                  onTap: () => _export(asJson: true),
                ),
                const Divider(height: 1, color: Color(0xFFEDE6DC)),
                ListTile(
                  leading: const Icon(Icons.table_view_outlined, color: kRed),
                  title: const Text('导出按日汇总（CSV）'),
                  subtitle: const Text('每天一行：应完成 / 已完成 / 完成率 / 睡前总结'),
                  trailing: const Icon(Icons.chevron_right),
                  enabled: !_exporting,
                  onTap: () => _export(asJson: false),
                ),
                if (_exporting)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: LinearProgressIndicator(minHeight: 3),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _Section('关于'),
          Card(
            child: Column(
              children: const [
                ListTile(
                  leading: Icon(Icons.info_outline, color: Color(0xFF8A837A)),
                  title: Text('每日打卡'),
                  subtitle: Text('版本 1.2.0 · 给上进的人'),
                ),
                Divider(height: 1, color: Color(0xFFEDE6DC)),
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Text(
                    '「自己动手，丰衣足食。」\n坚持一件小事，日拱一卒，功不唐捐。',
                    style: TextStyle(
                        fontSize: 13, height: 1.7, color: Color(0xFF7A4A3A)),
                  ),
                ),
                Divider(height: 1, color: Color(0xFFEDE6DC)),
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Text(
                    '小米 / MIUI 提示：若希望定时提醒稳定，请在「设置 → 应用设置 → '
                    '每日打卡」里打开「自启动」，并把省电策略设为「无限制」。',
                    style: TextStyle(
                        fontSize: 12.5, height: 1.7, color: Color(0xFF8A837A)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String text;
  const _Section(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(text,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF8A837A),
                letterSpacing: 1)),
      );
}

class _StatCard extends StatelessWidget {
  final int todayDone;
  final int todayTotal;
  final int streak;
  final int totalTasks;
  final int archivedTasks;
  const _StatCard({
    required this.todayDone,
    required this.todayTotal,
    required this.streak,
    required this.totalTasks,
    required this.archivedTasks,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _StatItem(label: '今日完成', value: '$todayDone/$todayTotal'),
            _StatItem(label: '连续全勤', value: '$streak 天'),
            _StatItem(label: '进行中', value: '$totalTasks'),
            _StatItem(label: '已归档', value: '$archivedTasks'),
          ],
        ),
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  const _StatItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700, color: kInk)),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF8A837A))),
      ],
    );
  }
}
