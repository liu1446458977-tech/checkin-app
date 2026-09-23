/// 应用壳：主题 + 底部五页（今日 / 睡前总结 / 看板 / 总览 / 设置）。
library;

import 'package:flutter/material.dart';

import 'db.dart';
import 'pages/board_page.dart';
import 'pages/home_page.dart';
import 'pages/onboarding_page.dart';
import 'pages/overview_page.dart';
import 'pages/settings_page.dart';
import 'pages/sleep_summary_page.dart';
import 'services/board_client.dart';
import 'services/secret_store.dart';
import 'services/profile.dart';
import 'services/summary_service.dart';

/// 简约而有力的配色：纸白底、教员红、墨黑字
const kRed = Color(0xFFC62828);
const kPaper = Color(0xFFFBF8F3);
const kInk = Color(0xFF26221E);
const kGold = Color(0xFFC9A227);
/// 休息日配色（与红色系区分开）
const kRest = Color(0xFF4A6FA5);
const kMuted = Color(0xFF8A837A);

/// 数据加载失败的兜底视图：任何加载错误都不能留下永久转圈的空白，
/// 给用户一个明确提示 + 重试入口。
class LoadErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const LoadErrorView({super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 44, color: Color(0xFFC9BFB2)),
            const SizedBox(height: 12),
            const Text('数据加载失败',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: kInk)),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFF8A837A)),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: kRed),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空白状态/无数据提示
class EmptyHint extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  const EmptyHint({super.key, required this.icon, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: const Color(0xFFC9BFB2)),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(color: kMuted, fontSize: 15)),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFB3A99C), fontSize: 12.5)),
            ],
          ],
        ),
      ),
    );
  }
}

class CheckinApp extends StatelessWidget {
  const CheckinApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '每日打卡',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kRed,
          surface: kPaper,
        ),
        scaffoldBackgroundColor: kPaper,
        appBarTheme: const AppBarTheme(
          backgroundColor: kPaper,
          foregroundColor: kInk,
          elevation: 0,
          centerTitle: true,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFEDE6DC)),
          ),
        ),
      ),
      home: const StartupGate(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // 冷启动自动补传今天的快照：哪怕用户只点开看板、不打今日页，别人也能看到进度。
    // 幂等（同一天重复上传只覆盖）、失败静默，绝不阻塞 UI。
    uploadToday().ignore();
    // 改过昵称的话，把服务器上的老数据迁移到新昵称名下（失败保留标记，下次冷启动再试）
    flushPendingRename().ignore();
  }

  /// 今日 / 睡前总结 / 看板 / 总览在切到它们时重新加载，避免 IndexedStack 常驻导致数据过期
  final _overviewKey = GlobalKey<OverviewPageState>();
  final _boardKey = GlobalKey<BoardPageState>();
  final _todayKey = GlobalKey<TodayPageState>();
  final _sleepKey = GlobalKey<SleepSummaryPageState>();

  static const _titles = ['每日打卡', '睡前总结', '看板', '总览总结', '设置'];

  @override
  Widget build(BuildContext context) {
    final pages = [
      TodayPage(key: _todayKey),
      SleepSummaryPage(key: _sleepKey),
      BoardPage(key: _boardKey),
      OverviewPage(key: _overviewKey),
      const SettingsPage(),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(_titles[_index])),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        backgroundColor: Colors.white,
        indicatorColor: kRed.withValues(alpha: 0.12),
        onDestinationSelected: (i) {
          setState(() => _index = i);
          // 切过去的时候顺手刷新一下，保证看到的是最新的
          if (i == 0) _todayKey.currentState?.reload();
          if (i == 1) _sleepKey.currentState?.reload();
          if (i == 2) _boardKey.currentState?.reload();
          if (i == 3) _overviewKey.currentState?.reload();
        },
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.today_outlined),
              selectedIcon: Icon(Icons.today),
              label: '今日'),
          NavigationDestination(
              icon: Icon(Icons.nightlight_outlined),
              selectedIcon: Icon(Icons.nightlight_round),
              label: '睡前总结'),
          NavigationDestination(
              icon: Icon(Icons.leaderboard_outlined),
              selectedIcon: Icon(Icons.leaderboard),
              label: '看板'),
          NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights),
              label: '总览'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置'),
        ],
      ),
    );
  }
}

/// 启动闸门：没配 API Key 且从没跳过过 → 先显示引导页；否则直接进主界面。
/// 任何判断异常都放行进主界面，绝不把用户卡在启动页（这是本项目的硬性原则）。
class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  bool? _needOnboarding;

  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    var need = false;
    try {
      final hasKey = await SecretStore.has(kSecretApiKey);
      final onboarded =
          (await Db.instance.getSetting(kSettingAiOnboarded)) == '1';
      // 昵称是必填的身份标识：没设过就必须再走一次引导页
      // （老版本升上来的用户没有昵称，这里会补上）
      final hasName = await hasUserName();
      need = !hasName || (!hasKey && !onboarded);
    } catch (e) {
      // 读不出来就当作已配置，直接进主界面
      debugPrint('[gate] 判断引导状态失败，直接进主界面: $e');
      need = false;
    }
    if (!mounted) return;
    setState(() => _needOnboarding = need);
  }

  @override
  Widget build(BuildContext context) {
    final need = _needOnboarding;
    if (need == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (need) {
      return OnboardingPage(
        onDone: () => setState(() => _needOnboarding = false),
      );
    }
    return const HomeShell();
  }
}
