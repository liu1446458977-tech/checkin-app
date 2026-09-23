/// 启动初始化：数据库 + 通知/WorkManager。
/// 在 runApp 之后于后台执行；任何一步失败都只记录日志，绝不阻塞/阻断 UI。
library;

import 'package:flutter/foundation.dart';

import 'db.dart';
import 'reminders.dart';

/// 全局启动 Future。UI 不依赖它渲染（首帧已由 runApp 立即绘制），
/// 仅用于需要感知「初始化完成」的场景，或测试中 await。
final Future<void> appBootstrap = _bootstrapNow();

Future<void> _bootstrapNow() async {
  // 1) 数据库：失败已忽略，页面自身也会懒加载并在失败时提示重试。
  try {
    await Db.instance.database;
  } catch (e, s) {
    debugPrint('[boot] DB 初始化失败（已忽略，页面会重试）: $e\n$s');
  }

  // 2) 通知 + WorkManager：失败只影响定时提醒能力，不影响主流程。
  try {
    await initReminders();
  } catch (e, s) {
    debugPrint('[boot] 提醒初始化失败（已忽略）: $e\n$s');
  }
}
