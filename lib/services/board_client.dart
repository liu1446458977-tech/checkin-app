/// 联云看板的客户端：把「今日快照」上传到自己的服务器，并拉回看板数据。
///
/// 刻意的取舍（改之前先看）：
///   - 用 `dart:io` 的 HttpClient，不引 http/dio —— 和 deepseek_client 同一套风格，
///     构建链越简单越好。
///   - **只上传业务数据，不下载**：手机是唯一数据源，服务器只是"给别人看的镜子"。
///     这里刻意没有任何「把任务从服务器拉回来写进本地库」的代码 —— 那一步一写，
///     就立刻变成双向同步（冲突、时钟、删除语义），完全不是三人自用该有的复杂度。
///   - 上传失败只记日志，**绝不阻塞打卡**：离线优先，联网只是加分项。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core_logic.dart';
import '../db.dart';
import '../models.dart';
import '../stats_service.dart';
import '../task_actions.dart';

/// 配置项存在 settings 表里（跟着导出一起备份）
const String kSettingBoardUrl = 'board_url'; // 留空 = 用内置默认地址
const String kSettingBoardKey = 'board_key'; // 可选共享口令
const String kSettingBoardEnabled = 'board_enabled'; // '1' / '0'，默认开

/// **内置的默认服务器地址**：装完 App 打开就能看，不需要任何人手动配置。
/// 换服务器时改这一行重新出包即可；用户也可以在设置里覆盖（覆盖值优先）。
const String kDefaultBoardUrl = 'http://glk0108.site:8787';

class BoardConfig {
  final String url;
  final String key;
  final bool enabled;

  const BoardConfig({this.url = '', this.key = '', this.enabled = false});

  /// 配置齐了才能用
  bool get usable => enabled && url.trim().isNotEmpty;

  /// 只看地址是否可用（不含上传开关）：关掉上传也能打开看板页看别人。
  bool get canView => url.trim().isNotEmpty;

  static Future<BoardConfig> load() async {
    final db = Db.instance;
    final url = (await db.getSetting(kSettingBoardUrl) ?? '').trim();
    final enabled = await db.getSetting(kSettingBoardEnabled);
    return BoardConfig(
      url: url.isEmpty ? kDefaultBoardUrl : url,
      key: (await db.getSetting(kSettingBoardKey) ?? '').trim(),
      // 没设置过 = 默认开启（老版本升上来的用户也一样，直接就能看）
      enabled: enabled == null ? true : enabled == '1',
    );
  }

  static Future<void> save({
    String? url,
    String? key,
    bool? enabled,
  }) async {
    final db = Db.instance;
    if (url != null) await db.setSetting(kSettingBoardUrl, url.trim());
    if (key != null) await db.setSetting(kSettingBoardKey, key.trim());
    if (enabled != null) {
      await db.setSetting(kSettingBoardEnabled, enabled ? '1' : '0');
    }
  }
}

/// 一次上传的结果（给设置页显示"上次同步"用）
class BoardResult {
  final bool ok;
  final String message;
  const BoardResult(this.ok, this.message);
}

class BoardClient {
  final BoardConfig cfg;
  final Duration timeout;

  const BoardClient(this.cfg, {this.timeout = const Duration(seconds: 20)});

  Map<String, String> get _headers => {
        'Content-Type': 'application/json; charset=utf-8',
        if (cfg.key.isNotEmpty) 'X-Checkin-Key': cfg.key,
      };

  /// 上传一天快照。同一天重复上传 = 覆盖（服务器按 name+date 做 upsert）。
  Future<BoardResult> upload(Map<String, dynamic> payload) async {
    if (!cfg.usable) return const BoardResult(false, '看板上传未开启');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.parse('${_base()}/api/day');
      final req = await client.postUrl(uri).timeout(timeout);
      _headers.forEach(req.headers.set);
      req.write(jsonEncode(payload));
      final resp = await req.close().timeout(timeout);
      final body = await resp.transform(utf8.decoder).join().timeout(timeout);
      if (resp.statusCode == 200) {
        return const BoardResult(true, '已同步');
      }
      if (resp.statusCode == 401) {
        return const BoardResult(false, '共享口令不正确');
      }
      return BoardResult(false, '服务器返回 ${resp.statusCode}：${_clip(body)}');
    } on TimeoutException {
      return const BoardResult(false, '上传超时（检查服务器地址和网络）');
    } on SocketException catch (e) {
      return BoardResult(false, '连不上服务器：${e.osError?.message ?? e.message}');
    } catch (e) {
      return BoardResult(false, '上传失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  /// 拉看板数据（只读，用于 App 内的看板页）。
  /// 只看自己的上传开关：地址内置且有效就能看别人进度，关了上传也不影响查看。
  Future<Map<String, dynamic>> fetchBoard({
    required String date,
    int days = 7,
  }) async {
    if (!cfg.canView) throw const BoardException('服务器地址为空');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.parse('${_base()}/api/board?date=$date&days=$days');
      final req = await client.getUrl(uri).timeout(timeout);
      _headers.forEach(req.headers.set);
      final resp = await req.close().timeout(timeout);
      final body = await resp.transform(utf8.decoder).join().timeout(timeout);
      if (resp.statusCode == 200) {
        return jsonDecode(body) as Map<String, dynamic>;
      }
      if (resp.statusCode == 401) {
        throw const BoardException('共享口令不对（去设置里改）');
      }
      throw BoardException('服务器返回 ${resp.statusCode}');
    } on TimeoutException {
      throw const BoardException('超时（检查服务器地址和网络）');
    } on SocketException catch (e) {
      throw BoardException('连不上服务器：${e.osError?.message ?? e.message}');
    } finally {
      client.close(force: true);
    }
  }

  /// 把老昵称的全部数据迁到新昵称名下（改昵称后用）。
  /// 服务端语义：同日冲突取「上传时间较新」的一份；老名没数据时是纯 no-op（幂等）。
  Future<BoardResult> renameUser(
      {required String from, required String to}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.parse('${_base()}/api/rename');
      final req = await client.postUrl(uri).timeout(timeout);
      _headers.forEach(req.headers.set);
      req.write(jsonEncode({'from': from, 'to': to}));
      final resp = await req.close().timeout(timeout);
      final body = await resp.transform(utf8.decoder).join().timeout(timeout);
      if (resp.statusCode == 200) {
        return const BoardResult(true, '已迁移');
      }
      return BoardResult(false, '服务器返回 ${resp.statusCode}：${_clip(body)}');
    } on TimeoutException {
      return const BoardResult(false, '迁移超时');
    } on SocketException catch (e) {
      return BoardResult(false, '连不上服务器：${e.osError?.message ?? e.message}');
    } catch (e) {
      return BoardResult(false, '迁移失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  String _base() {
    var u = cfg.url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  static String _clip(String s) =>
      s.length > 120 ? '${s.substring(0, 120)}…' : s;
}

class BoardException implements Exception {
  final String message;
  const BoardException(this.message);
  @override
  String toString() => message;
}

// ============================================================
// 本地 → 上传载荷
// ============================================================

/// 组装某一天的快照（就是服务器 /api/day 要的那个 JSON）。
/// 口径与 App 内「今日」页完全一致：周期任务完成一次即达成、休息日不计完成率。
Future<Map<String, dynamic>> buildDayPayload(
  Db db,
  DateTime day, {
  required String userName,
}) async {
  final d = todayOnly(day);
  final entries = await loadToday(db, d);
  final snap = await loadStats(from: d, to: d);
  final stat = snap.statAt(d);

  final tasks = <Map<String, dynamic>>[];
  for (final e in entries) {
    tasks.add({
      'uuid': e.task.uuid,
      'name': e.task.name,
      'kind': e.task.kind.name, // single | repeating | periodic
      'done': entryDone(e, d),
      if (e.task.kind == TaskKind.periodic) 'schedule': scheduleLabel(e.task),
      // 周期任务带上结构化起止日：服务器据此在「今天没上传」的日子里
      // 延续显示这条任务，直到完成或周期结束（看板数据稳定性靠它）
      if (e.task.kind == TaskKind.periodic) 'start': dateKey(e.task.ownerDate),
      if (e.task.kind == TaskKind.periodic)
        'end': dateKey(e.task.endDate!),
    });
  }

  final note = await db.getDailyNote(dateKey(d));
  return {
    'name': userName,
    'date': dateKey(d),
    'total': stat.total,
    'done': stat.done > stat.total ? stat.total : stat.done,
    'is_rest': stat.isRest,
    'streak': snap.streak(d),
    'app_version': kBoardAppVersion,
    'tasks': tasks,
    if (note != null && note.isNotEmpty)
      'note': {
        'gain': note.gain,
        'blocker': note.blocker,
        'tomorrow': note.tomorrow,
        'extra': note.extra,
      },
  };
}

/// 应用版本号（构建期注入，和导出的 JSON 用同一个值）
const String kBoardAppVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: '1.2.8+12');

/// 「重置昵称」时把老昵称记在这个设置里；重新设置昵称后自动请求服务器
/// 把老昵称的全部数据迁到新昵称名下（看板上不再出现两个名字）。
const String kSettingPendingRenameFrom = 'pending_rename_from';

/// 执行一次待办的昵称迁移。任何失败都保留标记，下次冷启动重试（服务端幂等）。
Future<BoardResult> flushPendingRename() async {
  try {
    final db = Db.instance;
    final from = ((await db.getSetting(kSettingPendingRenameFrom)) ?? '').trim();
    if (from.isEmpty) return const BoardResult(false, '没有待迁移的昵称');
    final to = ((await db.getSetting('user_name')) ?? '').trim();
    if (to.isEmpty) return const BoardResult(false, '新昵称还没设置');
    if (from == to) {
      // 重置后又改回原名：没什么可迁的
      await db.setSetting(kSettingPendingRenameFrom, '');
      return const BoardResult(true, '无需迁移');
    }
    final cfg = await BoardConfig.load();
    if (!cfg.canView) return const BoardResult(false, '服务器不可用');
    final r = await BoardClient(cfg).renameUser(from: from, to: to);
    if (r.ok) {
      await db.setSetting(kSettingPendingRenameFrom, '');
      debugPrint('[board] 昵称数据迁移完成：$from → $to');
    } else {
      debugPrint('[board] 昵称数据迁移失败（下次冷启动重试）：${r.message}');
    }
    return r;
  } catch (e) {
    return BoardResult(false, '迁移异常：$e');
  }
}

/// 上传「今天」的快照。任何失败都只记日志，不抛异常、不打扰用户。
/// 触发点：打卡 / 取消打卡 / 保存睡前总结 / 打开今日页（幂等，重复上传只是覆盖）。
Future<BoardResult> uploadToday({DateTime? day}) async {
  try {
    final cfg = await BoardConfig.load();
    if (!cfg.usable) return const BoardResult(false, '未启用');
    final name = await _userName();
    if (name.isEmpty) return const BoardResult(false, '还没设置昵称');
    final payload = await buildDayPayload(Db.instance, day ?? DateTime.now(),
        userName: name);
    return await BoardClient(cfg).upload(payload);
  } catch (e) {
    return BoardResult(false, '上传异常：$e');
  }
}

/// 昵称从 profile 设置里取（和引导页/设置页同一处）
Future<String> _userName() async {
  final v = await Db.instance.getSetting('user_name');
  return (v ?? '').trim();
}
