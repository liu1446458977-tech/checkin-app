/// 数据导出：JSON（完整备份）与 CSV（按日汇总，方便用 Excel 看）。
/// 通过 MethodChannel 调起系统「另存为」界面（ACTION_CREATE_DOCUMENT），
/// 由用户在任意位置选择保存路径——不需要任何存储权限，也不引入新插件。
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import '../core_logic.dart';
import '../db.dart';
import '../models.dart';
import '../stats_service.dart';

const MethodChannel kExportChannel =
    MethodChannel('dev.yuzi.checkin_app/export');

/// 应用版本号。
/// 之前这里硬编码 '1.1.0'，pubspec 升到 1.2.0 后就再也对不上了，
/// 导出的 JSON 里会写错误的版本。现在改为构建期注入（不想为读版本号再引
/// package_info_plus 这个插件）：
///   flutter build apk --dart-define=APP_VERSION=$(pubspec 里的 version)
/// 构建脚本 tool/build_apk.sh 会自动读 pubspec.yaml 传进来，默认值只是兜底。
const String kAppVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: '1.2.0+4');

class ExportService {
  ExportService._();

  static String _ts() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}-${two(n.hour)}${two(n.minute)}';
  }

  /// 完整 JSON 备份
  static Future<String> buildJson() async {
    final data = await Db.instance.exportAll();
    final map = <String, dynamic>{
      'app': 'checkin_app',
      'app_version': kAppVersion,
      'exported_at': DateTime.now().toIso8601String(),
      'schema_version': Db.schemaVersion,
      'tables': data,
    };
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  /// 按日汇总 CSV：日期,星期,休息日,应完成,已完成,完成率,已完成任务,收获,卡点,明天,其他
  static Future<String> buildCsv() async {
    final today = todayOnly(DateTime.now());
    // 从最早有记录的一天开始
    final all = await Db.instance.exportAll();
    var earliest = today;
    for (final row in [
      ...all['completions']!,
      ...all['daily_notes']!,
      ...all['tasks']!,
    ]) {
      // 归属日（新模型）优先，其次创建时间；start_date 是遗留列，兜底用
      final raw = (row['date'] ?? row['owner_date'] ?? row['start_date']) as String?;
      final ms = row['created_at'] as int?;
      DateTime? d;
      if (raw != null && raw.isNotEmpty) {
        final p = raw.split('-');
        if (p.length == 3) {
          final y = int.tryParse(p[0]), m = int.tryParse(p[1]), dd = int.tryParse(p[2]);
          if (y != null && m != null && dd != null) d = DateTime(y, m, dd);
        }
      }
      d ??= ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
      if (d != null && d.isBefore(earliest)) earliest = todayOnly(d);
    }

    final snap = await loadStats(from: earliest, to: today);
    final notes = <String, DailyNote>{
      for (final n in await Db.instance.dailyNotesInRange(
          dateKey(earliest), dateKey(today)))
        n.date: n,
    };
    final byId = <int, Task>{
      for (final t in snap.tasks)
        if (t.id != null) t.id!: t
    };

    final buf = StringBuffer()
      ..writeln('日期,星期,休息日,应完成,已完成,完成率,已完成任务,收获,卡点,明天,其他');
    const week = ['一', '二', '三', '四', '五', '六', '日'];
    for (var d = earliest; !d.isAfter(today); d = d.add(const Duration(days: 1))) {
      final key = dateKey(d);
      final st = snap.statAt(d);
      final note = notes[key];
      if (!st.hasData && (note == null || note.isEmpty)) continue;
      final doneNames = (snap.completions[key] ?? const <int>{})
          .map((id) => byId[id]?.name)
          .whereType<String>()
          .join(' / ');
      buf.writeln([
        key,
        '星期${week[d.weekday - 1]}',
        st.isRest ? '是' : '',
        '${st.total}',
        '${st.done}',
        st.isRest ? '' : '${(st.ratio * 100).round()}%',
        doneNames,
        note?.gain ?? '',
        note?.blocker ?? '',
        note?.tomorrow ?? '',
        note?.extra ?? '',
      ].map(_csv).join(','));
    }
    return buf.toString();
  }

  static String _csv(String v) {
    final t = v.replaceAll('"', '""');
    return '"$t"';
  }

  /// 调起系统「另存为」。返回保存到的 uri；用户取消返回 null。
  static Future<String?> saveText({
    required String name,
    required String mime,
    required String content,
  }) {
    return kExportChannel.invokeMethod<String>('saveText', {
      'name': name,
      'mime': mime,
      'content': content,
    });
  }

  static Future<String?> exportJson() async => saveText(
        name: 'checkin-backup-${_ts()}.json',
        mime: 'application/json',
        content: await buildJson(),
      );

  static Future<String?> exportCsv() async => saveText(
        name: 'checkin-daily-${_ts()}.csv',
        mime: 'text/csv',
        content: await buildCsv(),
      );
}
