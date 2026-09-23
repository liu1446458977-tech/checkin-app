/// SQLite 数据访问层。
/// 单例设计：每个 isolate（包括 WorkManager 后台 isolate）首次调用时独立建连。
library;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

class Db {
  Db._();
  static final Db instance = Db._();

  /// v1: tasks / subtasks / completions / subtask_checks / quote_usage / settings
  /// v2: + daily_notes（睡前总结）、rest_days / rest_weekdays（休息日）、
  ///     ai_summaries / ai_summaries_history（AI 总结）
  /// v3: tasks + end_date（周期任务的「周期截止日」，整个周期的体现）
  /// v4: tasks + owner_date / repeat_daily / uuid（「归属日 + 是否每天重复」新模型）
  ///     并把 daily 归一到 oneoff、回填归属日与 UUID。
  ///     weekdays / interval_days / deadline 三个旧列**保留但不读**：
  ///     SQLite 删列要重建整张表，违背非破坏迁移的约定。
  /// v5: 子任务下线（UI 与判定移除；表和数据保留）；把「子任务全勾选」的历史
  ///     补记成正式打卡记录，升级后完成率 / 连续达标不会凭空变差。
  static const int schemaVersion = 5;

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'checkin.db'),
      version: schemaVersion,
      onCreate: (db, version) async {
        await _createV1Tables(db);
        await _createV2Tables(db);
        await _applyV3(db);
        await _applyV4(db);
        await _applyV5(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // 非破坏性迁移：只新增表 / 新增列，不动任何旧数据。
        if (oldVersion < 2) {
          await _createV2Tables(db);
        }
        if (oldVersion < 3) {
          await _applyV3(db);
        }
        if (oldVersion < 4) {
          await _applyV4(db);
        }
        if (oldVersion < 5) {
          await _applyV5(db);
        }
      },
    );
    return _db!;
  }

  // ---------- Schema ----------

  static Future<void> _createV1Tables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tasks(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        color_index INTEGER NOT NULL DEFAULT 0,
        weekdays TEXT NOT NULL DEFAULT '',
        interval_days INTEGER NOT NULL DEFAULT 0,
        start_date TEXT,
        deadline TEXT,
        archived INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS subtasks(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        sort INTEGER NOT NULL DEFAULT 0
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS completions(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id INTEGER NOT NULL,
        date TEXT NOT NULL,
        done_at INTEGER NOT NULL,
        UNIQUE(task_id, date)
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS subtask_checks(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        subtask_id INTEGER NOT NULL,
        date TEXT NOT NULL,
        checked_at INTEGER NOT NULL,
        UNIQUE(subtask_id, date)
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS quote_usage(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text TEXT NOT NULL,
        used_at INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS settings(
        key TEXT PRIMARY KEY,
        value TEXT
      )''');
  }

  static Future<void> _createV2Tables(DatabaseExecutor db) async {
    // 睡前总结：一天一条，四个字段分列存储
    await db.execute('''
      CREATE TABLE IF NOT EXISTS daily_notes(
        date TEXT PRIMARY KEY,
        gain TEXT NOT NULL DEFAULT '',
        blocker TEXT NOT NULL DEFAULT '',
        tomorrow TEXT NOT NULL DEFAULT '',
        extra TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL DEFAULT 0
      )''');
    // 休息日（单日）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rest_days(
        date TEXT PRIMARY KEY,
        note TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL DEFAULT 0
      )''');
    // 休息日（每周固定，1=周一 .. 7=周日）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rest_weekdays(
        weekday INTEGER PRIMARY KEY,
        created_at INTEGER NOT NULL DEFAULT 0
      )''');
    // AI 总结（kind: week1/week2/week3/week4/half_first/half_second/month）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ai_summaries(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        period_start TEXT NOT NULL,
        period_end TEXT NOT NULL,
        period_label TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL DEFAULT '',
        metrics_json TEXT NOT NULL DEFAULT '',
        source_ids TEXT NOT NULL DEFAULT '',
        model TEXT NOT NULL DEFAULT '',
        prompt_version INTEGER NOT NULL DEFAULT 1,
        status TEXT NOT NULL DEFAULT 'ok',
        error TEXT,
        created_at INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0,
        UNIQUE(kind, period_start)
      )''');
    // 重新生成前的旧版本存档
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ai_summaries_history(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        summary_id INTEGER NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        metrics_json TEXT NOT NULL DEFAULT '',
        model TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL DEFAULT 0
      )''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_notes_date ON daily_notes(date)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_completions_date ON completions(date)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_checks_date ON subtask_checks(date)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_ai_period ON ai_summaries(kind, period_start)');
  }

  /// v3：给 tasks 增加 end_date（周期任务的周期截止日）。
  /// SQLite 的 ADD COLUMN 没有 IF NOT EXISTS，所以先查 PRAGMA 再决定，
  /// 保证迁移可以重复执行而不报错。
  static Future<void> _applyV3(DatabaseExecutor db) async {
    await _addColumnIfMissing(db, 'tasks', 'end_date', 'end_date TEXT');
  }

  /// v4：新任务模型（归属日 + 是否每天重复 + UUID）。
  /// 全程非破坏：只加列、只回填，不删列、不动任何打卡记录。
  /// 幂等：列先 PRAGMA 查再加，回填都带 WHERE 条件，重复执行结果一致。
  static Future<void> _applyV4(DatabaseExecutor db) async {
    await _addColumnIfMissing(db, 'tasks', 'owner_date', 'owner_date TEXT');
    await _addColumnIfMissing(
        db, 'tasks', 'repeat_daily', 'repeat_daily INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(db, 'tasks', 'uuid', 'uuid TEXT');

    // 旧的「每日任务」等价于新模型的「重复任务」
    await db.execute("UPDATE tasks SET repeat_daily = 1 WHERE type = 'daily'");
    // 归属日：周期任务取周期起始日，其余取创建当天（毫秒时间戳 → 本地日期）
    await db.execute('''
      UPDATE tasks SET owner_date = COALESCE(
        NULLIF(start_date, ''),
        date(created_at / 1000, 'unixepoch', 'localtime')
      )
      WHERE owner_date IS NULL
    ''');
    // 归一化类型名（新代码只把它当导出用的标签，判断一律由字段派生）
    await db.execute('''
      UPDATE tasks SET type = CASE
        WHEN repeat_daily = 1 THEN 'repeating'
        WHEN end_date IS NOT NULL AND end_date <> '' THEN 'periodic'
        ELSE 'single'
      END
    ''');
    // 旧数据补 UUID，方便以后上传服务器做看板时不撞车
    await db.execute(
        "UPDATE tasks SET uuid = lower(hex(randomblob(16))) WHERE uuid IS NULL OR uuid = ''");
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tasks_owner ON tasks(owner_date)');
  }

  /// v5：子任务功能下线。把历史上「子任务全部勾选 = 当天完成」的日子
  /// 补记成正式打卡记录（completions），否则这些天升级后会显示为未完成，
  /// 完成率和连续达标会凭空变差。只插不改不删；INSERT OR IGNORE +
  /// UNIQUE(task_id, date) 保证可重复执行。
  static Future<void> _applyV5(DatabaseExecutor db) async {
    await db.execute('''
      INSERT OR IGNORE INTO completions(task_id, date, done_at)
      SELECT s.task_id, c.date, MIN(c.checked_at)
      FROM subtask_checks c
      JOIN subtasks s ON s.id = c.subtask_id
      GROUP BY s.task_id, c.date
      HAVING COUNT(DISTINCT c.subtask_id) >= (
        SELECT COUNT(*) FROM subtasks s2 WHERE s2.task_id = s.task_id
      )
    ''');
  }

  static Future<void> _addColumnIfMissing(
    DatabaseExecutor db,
    String table,
    String column,
    String columnDdl,
  ) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    final exists = cols.any((c) => c['name'] == column);
    if (!exists) {
      await db.execute('ALTER TABLE $table ADD COLUMN $columnDdl');
    }
  }

  // ---------- Tasks ----------

  Future<List<Task>> getTasks({bool includeArchived = false}) async {
    final db = await database;
    final rows = await db.query('tasks',
        where: includeArchived ? null : 'archived = 0', orderBy: 'created_at');
    return rows.map(_taskFromRow).toList();
  }

  Future<Task?> getTask(int id) async {
    final db = await database;
    final rows = await db.query('tasks', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _taskFromRow(rows.first);
  }

  Future<int> addTask(Task t) async {
    final db = await database;
    return db.insert('tasks', _taskToRow(t));
  }

  Future<void> updateTask(Task t) async {
    final db = await database;
    await db.update('tasks', _taskToRow(t), where: 'id = ?', whereArgs: [t.id]);
  }

  Future<void> setArchived(int id, bool archived) async {
    final db = await database;
    await db.update('tasks', {'archived': archived ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 该任务累计打过多少次卡。UI 用它决定删除要不要「二次确认」。
  Future<int> completionCount(int taskId) async {
    final db = await database;
    final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM completions WHERE task_id = ?', [taskId]);
    return (rows.first['c'] as int?) ?? 0;
  }

  /// 硬删任务（连同它的打卡记录）。
  /// 调用方必须先确认：已经打过卡的任务要弹两次确认，防止手滑误删。
  Future<void> deleteTask(int id) async {
    final db = await database;
    await db.delete('subtask_checks',
        where: 'subtask_id IN (SELECT id FROM subtasks WHERE task_id = ?)',
        whereArgs: [id]);
    await db.delete('subtasks', where: 'task_id = ?', whereArgs: [id]);
    await db.delete('completions', where: 'task_id = ?', whereArgs: [id]);
    await db.delete('tasks', where: 'id = ?', whereArgs: [id]);
  }

  // 子任务（v5 起功能下线）：subtasks / subtask_checks 两张表保留作历史数据，
  // 代码不再读写；deleteTask 仍会顺手清理它们的行，避免留下孤儿数据。
  // ---------- Completions ----------

  Future<Set<String>> doneDates(int taskId) async {
    final db = await database;
    final rows = await db
        .query('completions', columns: ['date'], where: 'task_id = ?', whereArgs: [taskId]);
    return rows.map((r) => r['date'] as String).toSet();
  }

  Future<void> setTaskDone(int taskId, String date, {required bool done}) async {
    final db = await database;
    if (done) {
      await db.insert('completions',
          {'task_id': taskId, 'date': date, 'done_at': DateTime.now().millisecondsSinceEpoch},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    } else {
      await db.delete('completions',
          where: 'task_id = ? AND date = ?', whereArgs: [taskId, date]);
    }
  }

  /// 一次取出区间内所有打卡记录：date -> {taskId}
  Future<Map<String, Set<int>>> completionsInRange(
      String start, String end) async {
    final db = await database;
    final rows = await db.query('completions',
        columns: ['task_id', 'date'],
        where: 'date >= ? AND date <= ?',
        whereArgs: [start, end]);
    final out = <String, Set<int>>{};
    for (final r in rows) {
      (out[r['date'] as String] ??= <int>{}).add(r['task_id'] as int);
    }
    return out;
  }

  // ---------- Quotes ----------

  Future<List<String>> recentQuoteTexts({int limit = 8}) async {
    final db = await database;
    final rows = await db.query('quote_usage',
        orderBy: 'used_at DESC', limit: limit);
    return rows.map((r) => r['text'] as String).toList();
  }

  Future<void> addQuoteUsage(String text) async {
    final db = await database;
    await db.insert('quote_usage',
        {'text': text, 'used_at': DateTime.now().millisecondsSinceEpoch});
  }

  // ---------- Daily notes（睡前总结） ----------

  Future<DailyNote?> getDailyNote(String date) async {
    final db = await database;
    final rows =
        await db.query('daily_notes', where: 'date = ?', whereArgs: [date], limit: 1);
    return rows.isEmpty ? null : DailyNote.fromRow(rows.first);
  }

  /// 写入或更新睡前总结；四个字段全空时视为删除该天记录。
  Future<void> saveDailyNote(DailyNote note) async {
    final db = await database;
    if (note.isEmpty) {
      await db.delete('daily_notes', where: 'date = ?', whereArgs: [note.date]);
      return;
    }
    await db.insert('daily_notes', note.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteDailyNote(String date) async {
    final db = await database;
    await db.delete('daily_notes', where: 'date = ?', whereArgs: [date]);
  }

  Future<List<DailyNote>> dailyNotesInRange(String start, String end) async {
    final db = await database;
    final rows = await db.query('daily_notes',
        where: 'date >= ? AND date <= ?',
        whereArgs: [start, end],
        orderBy: 'date');
    return rows.map(DailyNote.fromRow).toList();
  }

  /// 有睡前总结的日期集合（写了的才算）
  Future<Set<String>> datesWithNotes(String start, String end) async {
    final db = await database;
    final rows = await db.query('daily_notes',
        columns: ['date'],
        where: "date >= ? AND date <= ? AND (trim(gain) <> '' OR trim(blocker) <> '' OR trim(tomorrow) <> '' OR trim(extra) <> '')",
        whereArgs: [start, end]);
    return rows.map((r) => r['date'] as String).toSet();
  }

  // ---------- Rest days（休息日） ----------

  Future<Set<String>> restDaysInRange(String start, String end) async {
    final db = await database;
    final rows = await db.query('rest_days',
        columns: ['date'],
        where: 'date >= ? AND date <= ?',
        whereArgs: [start, end]);
    return rows.map((r) => r['date'] as String).toSet();
  }

  Future<Set<String>> allRestDates() async {
    final db = await database;
    final rows = await db.query('rest_days', columns: ['date']);
    return rows.map((r) => r['date'] as String).toSet();
  }

  Future<Set<int>> weeklyRestWeekdays() async {
    final db = await database;
    final rows = await db.query('rest_weekdays', columns: ['weekday']);
    return rows.map((r) => r['weekday'] as int).toSet();
  }

  Future<void> addRestDay(String date, {String note = ''}) async {
    final db = await database;
    await db.insert('rest_days',
        {
          'date': date,
          'note': note,
          'created_at': DateTime.now().millisecondsSinceEpoch
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> removeRestDay(String date) async {
    final db = await database;
    await db.delete('rest_days', where: 'date = ?', whereArgs: [date]);
  }

  Future<void> setWeeklyRestWeekdays(Set<int> weekdays) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('rest_weekdays');
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final w in weekdays) {
        await txn.insert('rest_weekdays', {'weekday': w, 'created_at': now});
      }
    });
  }

  // ---------- Settings ----------

  Future<String?> getSetting(String key) async {
    final db = await database;
    final rows =
        await db.query('settings', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) async {
    final db = await database;
    await db.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---------- AI 总结 ----------

  Future<AiSummary?> getSummary(String kind, String periodStart) async {
    final db = await database;
    final rows = await db.query('ai_summaries',
        where: 'kind = ? AND period_start = ?',
        whereArgs: [kind, periodStart],
        limit: 1);
    return rows.isEmpty ? null : AiSummary.fromRow(rows.first);
  }

  Future<AiSummary?> getSummaryById(int id) async {
    final db = await database;
    final rows =
        await db.query('ai_summaries', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : AiSummary.fromRow(rows.first);
  }

  Future<List<AiSummary>> summariesInRange(
      String start, String end) async {
    final db = await database;
    final rows = await db.query('ai_summaries',
        where: 'period_start >= ? AND period_start <= ?',
        whereArgs: [start, end],
        orderBy: 'period_start, kind');
    return rows.map(AiSummary.fromRow).toList();
  }

  /// 写入或覆盖一条总结。覆盖前把旧版本存进历史表（只在旧版本正常时才存档）。
  Future<int> saveSummary(AiSummary s) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction<int>((txn) async {
      final existing = await txn.query('ai_summaries',
          where: 'kind = ? AND period_start = ?',
          whereArgs: [s.kind, s.periodStart],
          limit: 1);
      var id = s.id;
      if (existing.isNotEmpty) {
        final old = AiSummary.fromRow(existing.first);
        id = old.id;
        if (old.isOk) {
          await txn.insert('ai_summaries_history', {
            'summary_id': old.id,
            'content': old.content,
            'metrics_json': old.metricsJson,
            'model': old.model,
            'created_at': old.updatedAt == 0 ? now : old.updatedAt,
          });
        }
        await txn.update(
          'ai_summaries',
          {...s.toRow(), 'id': id, 'created_at': old.createdAt == 0 ? now : old.createdAt, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [id],
        );
      } else {
        id = await txn.insert('ai_summaries',
            {...s.toRow(), 'created_at': now, 'updated_at': now});
      }
      return id!;
    });
  }

  Future<List<AiSummaryHistory>> summaryHistory(int summaryId) async {
    final db = await database;
    final rows = await db.query('ai_summaries_history',
        where: 'summary_id = ?',
        whereArgs: [summaryId],
        orderBy: 'created_at DESC');
    return rows.map(AiSummaryHistory.fromRow).toList();
  }

  // ---------- 导出 ----------

  /// 整库导出（导出功能用，一次性取出所有表）。
  /// AI 总结也是真金白银生成的，必须在备份里——之前漏了这两张表。
  Future<Map<String, List<Map<String, Object?>>>> exportAll() async {
    final db = await database;
    return {
      'tasks': await db.query('tasks', orderBy: 'id'),
      'subtasks': await db.query('subtasks', orderBy: 'id'),
      'completions': await db.query('completions', orderBy: 'date, task_id'),
      'subtask_checks': await db.query('subtask_checks', orderBy: 'date'),
      'daily_notes': await db.query('daily_notes', orderBy: 'date'),
      'rest_days': await db.query('rest_days', orderBy: 'date'),
      'rest_weekdays': await db.query('rest_weekdays', orderBy: 'weekday'),
      'quote_usage': await db.query('quote_usage', orderBy: 'id'),
      'settings': await db.query('settings', orderBy: 'key'),
      'ai_summaries': await db.query('ai_summaries', orderBy: 'period_start'),
      'ai_summaries_history':
          await db.query('ai_summaries_history', orderBy: 'summary_id, id'),
    };
  }

  // ---------- Mapping ----------

  /// 只写新模型用到的列。weekdays / interval_days / deadline 是遗留列：
  /// 更新时不写（保留原值）、插入时靠表默认值，总之不再参与任何业务判断。
  Map<String, Object?> _taskToRow(Task t) => {
        if (t.id != null) 'id': t.id,
        'uuid': t.uuid.isEmpty ? newTaskUuid() : t.uuid,
        'name': t.name,
        'type': t.kind.name,
        'note': t.note,
        'color_index': t.colorIndex,
        'owner_date': _d(t.ownerDate),
        'repeat_daily': t.repeatDaily ? 1 : 0,
        'end_date': t.endDate == null ? null : _d(t.endDate!),
        'archived': t.archived ? 1 : 0,
        'created_at': t.createdAt.millisecondsSinceEpoch,
      };

  Task _taskFromRow(Map<String, Object?> r) {
    final created =
        DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int);
    // 归属日优先读新列；老库兜底：周期任务用 start_date，其余用创建当天
    final owner = _parseDate(r['owner_date'] as String?) ??
        _parseDate(r['start_date'] as String?) ??
        DateTime(created.year, created.month, created.day);
    return Task(
      id: r['id'] as int,
      uuid: (r['uuid'] as String?) ?? '',
      name: r['name'] as String,
      note: (r['note'] as String?) ?? '',
      colorIndex: (r['color_index'] as int?) ?? 0,
      ownerDate: owner,
      // type = 'daily' 是兜底：万一读到还没跑 v4 迁移的老库也不会丢语义
      repeatDaily:
          ((r['repeat_daily'] as int?) ?? 0) == 1 || r['type'] == 'daily',
      endDate: _parseDate(r['end_date'] as String?),
      archived: (r['archived'] as int?) == 1,
      createdAt: created,
    );
  }

  static String _d(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static DateTime? _parseDate(String? s) {
    if (s == null || s.isEmpty) return null;
    final parts = s.split('-').map(int.parse).toList();
    return DateTime(parts[0], parts[1], parts[2]);
  }
}
