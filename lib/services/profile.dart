/// 用户身份：昵称。
///
/// 刻意**不做**一整套登录系统（注册/改密/找回/邮箱验证），3 个人自用根本不需要。
/// 昵称在首次进入时设置一次、之后不可修改，它本身就是身份标识：
/// 以后把「今日完成情况」上传服务器做看板时，服务器就按这个昵称硬性隔离，
/// 谁也别想冒充谁——因为昵称根本改不了。
library;

import '../db.dart';

const String kSettingUserName = 'user_name';

/// 当前昵称（没设置过返回空串）
Future<String> userName() async =>
    ((await Db.instance.getSetting(kSettingUserName)) ?? '').trim();

/// 昵称是否已设置
Future<bool> hasUserName() async => (await userName()).isNotEmpty;

/// 只允许在引导页调用一次；设置页只读展示，不给修改入口。
Future<void> setUserName(String name) async {
  final n = name.trim();
  if (n.isEmpty) return;
  await Db.instance.setSetting(kSettingUserName, n);
}
