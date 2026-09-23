"""v4 + v5 迁移 SQL 的独立验证（不依赖 Flutter/Dart）。

造一个 v3 老库（含 daily / periodic / oneoff 三种老任务 + 打卡记录），
跑一遍新代码里 _applyV4 / _applyV5 的同样 SQL，检查：
  1) 全新安装路径：建表 + 迁移是否干净
  2) 逐级升级路径：v3 老数据 → 归属日/重复标记/类型是否合理
  3) 重复执行路径：再跑一次是否幂等（结果与第一次一致）
  4) 打卡记录、睡前总结等历史数据是否毫发无损
"""

import os
import shutil
import sqlite3
import tempfile

# 与 lib/db.dart 的 _applyV4 保持逐字一致（含顺序）
MIGRATION = [
    "ALTER TABLE tasks ADD COLUMN owner_date TEXT",
    "ALTER TABLE tasks ADD COLUMN repeat_daily INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE tasks ADD COLUMN uuid TEXT",
    "UPDATE tasks SET repeat_daily = 1 WHERE type = 'daily'",
    """
      UPDATE tasks SET owner_date = COALESCE(
        NULLIF(start_date, ''),
        date(created_at / 1000, 'unixepoch', 'localtime')
      )
      WHERE owner_date IS NULL
    """,
    """
      UPDATE tasks SET type = CASE
        WHEN repeat_daily = 1 THEN 'repeating'
        WHEN end_date IS NOT NULL AND end_date <> '' THEN 'periodic'
        ELSE 'single'
      END
    """,
    "UPDATE tasks SET uuid = lower(hex(randomblob(16))) WHERE uuid IS NULL OR uuid = ''",
    "CREATE INDEX IF NOT EXISTS idx_tasks_owner ON tasks(owner_date)",
]

# 与 lib/db.dart 的 _applyV5 保持逐字一致：把「子任务全部勾选」的历史补记成打卡记录
MIGRATION_V5 = [
    """
      INSERT OR IGNORE INTO completions(task_id, date, done_at)
      SELECT s.task_id, c.date, MIN(c.checked_at)
      FROM subtask_checks c
      JOIN subtasks s ON s.id = c.subtask_id
      GROUP BY s.task_id, c.date
      HAVING COUNT(DISTINCT c.subtask_id) >= (
        SELECT COUNT(*) FROM subtasks s2 WHERE s2.task_id = s.task_id
      )
    """,
]

V1_TABLES = """
CREATE TABLE IF NOT EXISTS tasks(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL, type TEXT NOT NULL, note TEXT NOT NULL DEFAULT '',
  color_index INTEGER NOT NULL DEFAULT 0, weekdays TEXT NOT NULL DEFAULT '',
  interval_days INTEGER NOT NULL DEFAULT 0, start_date TEXT, deadline TEXT,
  archived INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS subtasks(
  id INTEGER PRIMARY KEY AUTOINCREMENT, task_id INTEGER NOT NULL,
  name TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS completions(
  id INTEGER PRIMARY KEY AUTOINCREMENT, task_id INTEGER NOT NULL,
  date TEXT NOT NULL, done_at INTEGER NOT NULL, UNIQUE(task_id, date));
CREATE TABLE IF NOT EXISTS subtask_checks(
  id INTEGER PRIMARY KEY AUTOINCREMENT, subtask_id INTEGER NOT NULL,
  date TEXT NOT NULL, checked_at INTEGER NOT NULL, UNIQUE(subtask_id, date));
CREATE TABLE IF NOT EXISTS quote_usage(
  id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, used_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT);
"""

V2_TABLES = """
CREATE TABLE IF NOT EXISTS daily_notes(
  date TEXT PRIMARY KEY, gain TEXT NOT NULL DEFAULT '', blocker TEXT NOT NULL DEFAULT '',
  tomorrow TEXT NOT NULL DEFAULT '', extra TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS rest_days(
  date TEXT PRIMARY KEY, note TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS rest_weekdays(
  weekday INTEGER PRIMARY KEY, created_at INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS ai_summaries(
  id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, period_start TEXT NOT NULL,
  period_end TEXT NOT NULL, period_label TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '', metrics_json TEXT NOT NULL DEFAULT '',
  source_ids TEXT NOT NULL DEFAULT '', model TEXT NOT NULL DEFAULT '',
  prompt_version INTEGER NOT NULL DEFAULT 1, status TEXT NOT NULL DEFAULT 'ok',
  error TEXT, created_at INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0,
  UNIQUE(kind, period_start));
CREATE TABLE IF NOT EXISTS ai_summaries_history(
  id INTEGER PRIMARY KEY AUTOINCREMENT, summary_id INTEGER NOT NULL,
  content TEXT NOT NULL DEFAULT '', metrics_json TEXT NOT NULL DEFAULT '',
  model TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL DEFAULT 0);
"""

MS = 1000
def ts(y, m, d):  # 本地时间毫秒时间戳
    import datetime
    return int(datetime.datetime(y, m, d, 12, 0).timestamp() * MS)


def seed_v3(path):
    """造一个 v3 库：三种老任务 + 打卡 + 子任务 + 总结。"""
    con = sqlite3.connect(path)
    con.executescript(V1_TABLES)
    con.executescript(V2_TABLES)
    con.execute("ALTER TABLE tasks ADD COLUMN end_date TEXT")
    rows = [
        # id, name, type, weekdays, interval_days, start_date, end_date, deadline, archived, created_at
        (1, "背单词", "daily", "", 0, None, None, None, 0, ts(2026, 1, 1)),
        (2, "瘦2斤", "periodic", "", 0, "2026-01-01", "2026-01-10", None, 0, ts(2026, 1, 1)),
        (3, "交实验报告", "oneoff", "", 0, None, None, "2026-01-05", 0, ts(2026, 1, 1)),
        (4, "老归档任务", "daily", "", 0, None, None, None, 1, ts(2025, 12, 20)),
        (5, "每周一健身", "periodic", "1", 0, None, None, None, 0, ts(2026, 1, 1)),
    ]
    con.executemany(
        "INSERT INTO tasks(id,name,type,weekdays,interval_days,start_date,end_date,"
        "deadline,archived,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)", rows)
    con.executemany("INSERT INTO completions(task_id,date,done_at) VALUES(?,?,?)",
                    [(1, "2026-01-01", ts(2026, 1, 1)), (2, "2026-01-03", ts(2026, 1, 3)),
                     (3, "2026-01-01", ts(2026, 1, 1)), (1, "2026-01-02", ts(2026, 1, 2))])
    con.execute("INSERT INTO subtasks(task_id,name,sort) VALUES(1,'list1',0)")
    con.execute("INSERT INTO subtask_checks(subtask_id,date,checked_at) VALUES(1,'2026-01-01',?)",
                (ts(2026, 1, 1),))
    # v5 回填用例：task1 共 3 个子任务 —— 1/5 只勾了 2 号（不应回填）；
    # 1/6 三个全勾（应回填）；1/1 已有打卡记录（INSERT OR IGNORE 不重复插）
    con.execute("INSERT INTO subtasks(task_id,name,sort) VALUES(1,'list2',1)")
    con.execute("INSERT INTO subtasks(task_id,name,sort) VALUES(1,'list3',2)")
    for sid, (y, m, d) in [(2, (2026, 1, 5)), (1, (2026, 1, 6)), (2, (2026, 1, 6)), (3, (2026, 1, 6))]:
        con.execute("INSERT INTO subtask_checks(subtask_id,date,checked_at) VALUES(?,?,?)",
                    (sid, f"{y:04d}-{m:02d}-{d:02d}", ts(y, m, d)))
    con.execute("INSERT INTO daily_notes(date,gain,updated_at) VALUES('2026-01-01','今天学到了',?)",
                (ts(2026, 1, 1),))
    con.execute("INSERT INTO rest_days(date,note,created_at) VALUES('2026-01-04','',?)", (ts(2026, 1, 4),))
    con.execute("INSERT INTO rest_weekdays(weekday,created_at) VALUES(7,?)", (ts(2026, 1, 1),))
    con.execute("INSERT INTO ai_summaries(kind,period_start,period_end,content) "
                "VALUES('week1','2026-01-01','2026-01-07','总结正文')")
    con.execute("INSERT INTO settings(key,value) VALUES('remind_hour','22')")
    con.execute("PRAGMA user_version = 3")
    con.commit()
    con.close()


def snapshot(con, new_cols=True):
    q = lambda s: con.execute(s).fetchall()
    task_cols = ("id,name,type,owner_date,repeat_daily,end_date,archived,uuid"
                 if new_cols else "id,name,type,start_date,end_date,archived")
    return {
        "columns": [r[1] for r in q("PRAGMA table_info(tasks)")],
        "tasks": q(f"SELECT {task_cols} FROM tasks ORDER BY id"),
        "completions": q("SELECT task_id,date FROM completions ORDER BY task_id,date"),
        "checks": q("SELECT subtask_id,date FROM subtask_checks"),
        "notes": q("SELECT date,gain FROM daily_notes"),
        "rest": q("SELECT date FROM rest_days"),
        "rest_wd": q("SELECT weekday FROM rest_weekdays"),
        "summaries": q("SELECT kind,period_start,content FROM ai_summaries"),
        "settings": q("SELECT key,value FROM settings"),
        "indexes": sorted(r[0] for r in q("SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'")),
    }


def run_migration(path):
    con = sqlite3.connect(path)
    for stmt in MIGRATION:
        # 列已存在时跳过，模拟 _addColumnIfMissing 的幂等
        if stmt.startswith("ALTER TABLE tasks ADD COLUMN"):
            col = stmt.split()[5]
            cols = [r[1] for r in con.execute("PRAGMA table_info(tasks)")]
            if col in cols:
                continue
        con.execute(stmt)
    for stmt in MIGRATION_V5:
        con.execute(stmt)
    con.commit()
    con.close()


def check(label, cond, extra=""):
    mark = "PASS" if cond else "FAIL"
    print(f"  [{mark}] {label}{(' — ' + extra) if extra else ''}")
    return cond


def main():
    tmp = tempfile.mkdtemp(prefix="checkin-mig-")
    src = os.path.join(tmp, "old.db")
    seed_v3(src)
    before = snapshot(sqlite3.connect(src), new_cols=False)

    ok = True
    # ---- 路径1：v3 → v4 逐级升级 ----
    print("① 逐级升级 v3 → v4")
    up = os.path.join(tmp, "upgraded.db")
    shutil.copy(src, up)
    run_migration(up)
    con = sqlite3.connect(up)
    s1 = snapshot(con)
    t = {r[0]: r for r in s1["tasks"]}
    ok &= check("tasks 新增 owner_date / repeat_daily / uuid 三列",
                {"owner_date", "repeat_daily", "uuid"}.issubset(set(s1["columns"])))
    ok &= check("老 daily → repeat_daily=1", t[1][4] == 1)
    ok &= check("老 daily 的 owner_date = 创建当天(1/1)", t[1][3] == "2026-01-01", t[1][3])
    ok &= check("老 periodic 的 owner_date = start_date(1/1)", t[2][3] == "2026-01-01", t[2][3])
    ok &= check("老 periodic 保留 end_date(1/10)", t[2][5] == "2026-01-10")
    ok &= check("oneoff 的 owner_date = 创建当天", t[3][3] == "2026-01-01")
    ok &= check("归档任务同样回填", t[4][3] == "2025-12-20", str(t[4][3]))
    ok &= check("每条任务都有 32 位 uuid", all(len(r[7] or "") == 32 for r in s1["tasks"]))
    ok &= check("uuid 互不重复", len({r[7] for r in s1["tasks"]}) == len(s1["tasks"]))
    ok &= check("类型名归一化", {r[2] for r in s1["tasks"]} <= {"repeating", "periodic", "single"},
                str(sorted({r[2] for r in s1["tasks"]})))
    ok &= check("旧打卡记录一条不丢", set(before["completions"]) <= set(s1["completions"]))
    ok &= check("v5 回填：子任务全勾选的 1/6 补记成打卡", (1, "2026-01-06") in s1["completions"])
    ok &= check("v5 不误伤：只勾一半的 1/5 不回填", (1, "2026-01-05") not in s1["completions"])
    ok &= check("v5 不重复插：1/1 仍只有一条", s1["completions"].count((1, "2026-01-01")) == 1)
    ok &= check("子任务勾选不丢", s1["checks"] == before["checks"])
    ok &= check("睡前总结不丢", s1["notes"] == before["notes"])
    ok &= check("休息日不丢（单日 + 每周）", s1["rest"] == before["rest"] and s1["rest_wd"] == before["rest_wd"])
    ok &= check("AI 总结不丢", s1["summaries"] == before["summaries"])
    ok &= check("设置不丢", s1["settings"] == before["settings"])
    ok &= check("建了 idx_tasks_owner 索引", "idx_tasks_owner" in s1["indexes"])
    ok &= check("旧列 weekdays/interval_days/deadline 仍在（非破坏）",
                {"weekdays", "interval_days", "deadline"}.issubset(set(s1["columns"])))
    con.close()

    # ---- 路径2：重复执行（幂等） ----
    print("② 再跑一遍迁移（幂等性）")
    run_migration(up)
    run_migration(up)
    con = sqlite3.connect(up)
    s2 = snapshot(con)
    con.close()
    # uuid 会因为 WHERE 条件而不被重写，owner_date/type 重算结果一致
    ok &= check("第二次执行后任务行完全一致", s2["tasks"] == s1["tasks"])
    ok &= check("第二次执行后打卡记录一致", s2["completions"] == s1["completions"])
    ok &= check("v5 重复执行不新增行", s2["completions"] == s1["completions"])
    ok &= check("第二次执行后列集合一致", s2["columns"] == s1["columns"])

    # ---- 路径3：全新安装（v1+v2+v3+v4 一次到位） ----
    print("③ 全新安装（onCreate 一次建全）")
    fresh = os.path.join(tmp, "fresh.db")
    con = sqlite3.connect(fresh)
    con.executescript(V1_TABLES)
    con.executescript(V2_TABLES)
    con.execute("ALTER TABLE tasks ADD COLUMN end_date TEXT")
    con.commit()
    con.close()
    run_migration(fresh)
    con = sqlite3.connect(fresh)
    s3 = snapshot(con)
    con.close()
    ok &= check("空库迁移后结构可用（列齐全）",
                {"owner_date", "repeat_daily", "uuid"}.issubset(set(s3["columns"])))
    ok &= check("空库迁移后没有任务行", s3["tasks"] == [])
    ok &= check("空库 v5 无副作用（completions 仍为空）", s3["completions"] == [])
    ok &= check("空库迁移不报错且索引就位", "idx_tasks_owner" in s3["indexes"])

    shutil.rmtree(tmp, ignore_errors=True)
    print("\n总体：", "全部通过 ✅" if ok else "存在失败 ❌")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
