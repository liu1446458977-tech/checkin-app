/// 提醒设置 + 「今天还剩几项没完成」的上报。
///
/// 闹钟和通知**全部在原生侧**（`android/.../Reminders.kt`），这里只做三件事：
///   1) 把用户设置（几点提醒 / 开不开）同步给原生；
///   2) App 在前台时把「今天还剩几项没完成」推给原生，闹钟响时原生据此拼文案；
///   3) 通知权限的申请与查询。
///
/// 为什么砍掉 workmanager：它为了"每 15 分钟检查一次"要拉起一个后台 Flutter
/// isolate，代价是多一个插件 + 一整套 Kotlin/KGP 构建坑（AGENTS.md 里记的
/// 「找不到符号 WorkmanagerPlugin」就是它）。我们真正需要的只是「到点响一次」，
/// 原生 AlarmManager 用 setAndAllowWhileIdle 就够，App 完全不用活着，
/// 而且**不需要任何新权限**。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'core_logic.dart';
import 'db.dart';

const MethodChannel kReminderChannel =
    MethodChannel('dev.yuzi.checkin_app/reminders');

/// 提醒设置键（存在 settings 表里，跟着导出一起备份）
const String kSettingRemindHour = 'remind_hour';
const String kSettingRemindEnabled = 'remind_enabled';
const int kDefaultRemindHour = 22;

Future<int> remindHour() async {
  final raw = await Db.instance.getSetting(kSettingRemindHour);
  final h = int.tryParse(raw ?? '') ?? kDefaultRemindHour;
  return h.clamp(0, 23);
}

Future<bool> remindEnabled() async =>
    (await Db.instance.getSetting(kSettingRemindEnabled) ?? '1') == '1';

/// 启动时调用：把当前设置同步给原生（幂等，重复调用安全）。
Future<void> initReminders() async {
  await syncReminderSchedule(
    hour: await remindHour(),
    enabled: await remindEnabled(),
  );
}

/// 把设置推给原生：enabled=false 就撤销闹钟。
Future<void> syncReminderSchedule({
  required int hour,
  required bool enabled,
}) async {
  try {
    if (enabled) {
      await kReminderChannel.invokeMethod<bool>('schedule', {'hour': hour});
    } else {
      await kReminderChannel.invokeMethod<bool>('cancel');
    }
  } catch (e) {
    // 提醒是可选能力，失败绝不能影响主流程
    debugPrint('[remind] 排闹钟失败（已忽略）: $e');
  }
}

/// App 在前台算好的「今天还剩几项没完成」推给原生。
/// 数量为 0 时原生不会发通知——全做完了就不打扰。
Future<void> pushUndoneCache(Db db, DateTime now) async {
  try {
    final n = await countUndoneToday(db, now);
    await kReminderChannel
        .invokeMethod<bool>('setUndone', {'count': n, 'date': dateKey(now)});
  } catch (e) {
    debugPrint('[remind] 上报未完成数失败（已忽略）: $e');
  }
}

/// 现在能不能发通知（权限已授予 且 通知未被系统关掉）
Future<bool> notificationReady() async {
  try {
    return await kReminderChannel.invokeMethod<bool>('status') ?? false;
  } catch (e) {
    return false;
  }
}

/// 申请通知权限（Android 13+ 才需要）。
/// 返回申请之后是否已经可用；返回 false 时由设置页引导去系统设置里开。
Future<bool> requestNotificationPermission() async {
  try {
    return await kReminderChannel
            .invokeMethod<bool>('requestPermission') ??
        false;
  } catch (e) {
    return false;
  }
}

/// 发一条测试提醒，让用户确认权限没问题。
Future<void> showTestNotification() async {
  try {
    await kReminderChannel.invokeMethod<bool>('test');
  } catch (e) {
    debugPrint('[remind] 测试通知失败: $e');
  }
}

/// 统计今日「应当出现但未完成」的任务数。
/// 口径与「今日」列表完全一致：周期任务完成一次即达成，不会一直催你。
Future<int> countUndoneToday(Db db, DateTime now) async {
  final tasks = await db.getTasks();
  var undone = 0;
  for (final t in tasks) {
    if (!appearsToday(t, now)) continue;
    final done = await db.doneDates(t.id!);
    if (taskDoneForDisplay(t, now, doneDates: done)) {
      continue;
    }
    undone++;
  }
  return undone;
}
