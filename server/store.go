package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	_ "modernc.org/sqlite" // 纯 Go 的 SQLite 驱动：交叉编译不需要 cgo
)

// schemaVersion 记在 PRAGMA user_version 上。以后加字段时按
// 「只加列、只回填，不删列」的非破坏原则做迁移（和 App 侧同一套规矩）。
const schemaVersion = 1

type store struct {
	db *sql.DB
	// 写操作串行化：SQLite 单写者，3 个人用它根本不需要更复杂的东西，
	// 一把互斥锁比调 SQLITE_BUSY 重试简单得多，也不会写坏数据。
	mu sync.Mutex
}

func openStore(path string) (*store, error) {
	dsn := path + "?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// 单写者模型：限制连接数，避免多连接下 WAL 的锁竞争
	db.SetMaxOpenConns(1)
	if err := db.Ping(); err != nil {
		return nil, err
	}
	s := &store{db: db}
	if err := s.migrate(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *store) Close() error { return s.db.Close() }

func (s *store) migrate() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS day_snapshots (
			id           INTEGER PRIMARY KEY AUTOINCREMENT,
			user_name    TEXT    NOT NULL,
			date         TEXT    NOT NULL,
			uploaded_at  INTEGER NOT NULL,
			total        INTEGER NOT NULL DEFAULT 0,
			done         INTEGER NOT NULL DEFAULT 0,
			is_rest      INTEGER NOT NULL DEFAULT 0,
			streak       INTEGER NOT NULL DEFAULT 0,
			app_version  TEXT    NOT NULL DEFAULT '',
			tasks_json   TEXT    NOT NULL DEFAULT '[]',
			note_gain    TEXT    NOT NULL DEFAULT '',
			note_blocker TEXT    NOT NULL DEFAULT '',
			note_tomorrow TEXT   NOT NULL DEFAULT '',
			note_extra   TEXT    NOT NULL DEFAULT '',
			UNIQUE(user_name, date)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_snapshots_date ON day_snapshots(date)`,
		`CREATE INDEX IF NOT EXISTS idx_snapshots_user ON day_snapshots(user_name, date)`,
	}
	for _, q := range stmts {
		if _, err := s.db.Exec(q); err != nil {
			return fmt.Errorf("迁移失败(%s): %w", firstLine(q), err)
		}
	}
	var v int
	if err := s.db.QueryRow("PRAGMA user_version").Scan(&v); err != nil {
		return err
	}
	if v < schemaVersion {
		if _, err := s.db.Exec(fmt.Sprintf("PRAGMA user_version = %d", schemaVersion)); err != nil {
			return err
		}
	}
	return nil
}

func firstLine(s string) string {
	for i, r := range s {
		if r == '\n' {
			return s[:i]
		}
	}
	return s
}

// DaySnapshot 是看板要展示的一行：某人某天的完成情况。
type DaySnapshot struct {
	Name       string     `json:"name"`
	Date       string     `json:"date"`
	Total      int        `json:"total"`
	Done       int        `json:"done"`
	IsRest     bool       `json:"is_rest"`
	Streak     int        `json:"streak"`
	Tasks      []TaskItem `json:"tasks"`
	Note       *Note      `json:"note,omitempty"`
	UploadedAt int64      `json:"uploaded_at"`
	AppVersion string     `json:"app_version,omitempty"`
	// Carried 表示这不是当天的真实上传，而是服务器用最近一次上传
	// 合成出来的「延续卡」（人没打开 App，但周期任务还在进行中）。
	Carried  bool   `json:"carried,omitempty"`
	LastSync string `json:"last_sync,omitempty"` // 延续卡取自哪一天的上传
}

// UpsertDay 写入或覆盖「某人某天」的快照。
// 同一天重复上传按覆盖处理（App 每改一次就打一次卡，覆盖比追加更符合直觉）。
func (s *store) UpsertDay(u DayUpload) error {
	tasksJSON, err := json.Marshal(u.Tasks)
	if err != nil {
		return err
	}
	n := Note{}
	if u.Note != nil {
		n = *u.Note
	}
	rest := 0
	if u.IsRest {
		rest = 1
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err = s.db.Exec(`
		INSERT INTO day_snapshots
			(user_name, date, uploaded_at, total, done, is_rest, streak, app_version,
			 tasks_json, note_gain, note_blocker, note_tomorrow, note_extra)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(user_name, date) DO UPDATE SET
			uploaded_at=excluded.uploaded_at,
			total=excluded.total,
			done=excluded.done,
			is_rest=excluded.is_rest,
			streak=excluded.streak,
			app_version=excluded.app_version,
			tasks_json=excluded.tasks_json,
			note_gain=excluded.note_gain,
			note_blocker=excluded.note_blocker,
			note_tomorrow=excluded.note_tomorrow,
			note_extra=excluded.note_extra`,
		u.Name, u.Date, time.Now().Unix(), u.Total, u.Done, rest, u.Streak, u.AppVersion,
		string(tasksJSON), n.Gain, n.Blocker, n.Tomorrow, n.Extra)
	return err
}

// BoardOn 取某一天所有人的快照，按「完成数多的在前」排。
func (s *store) BoardOn(date string) ([]DaySnapshot, error) {
	rows, err := s.db.Query(`
		SELECT user_name, date, total, done, is_rest, streak, app_version,
		       tasks_json, note_gain, note_blocker, note_tomorrow, note_extra, uploaded_at
		FROM day_snapshots WHERE date = ?
		ORDER BY (CAST(done AS REAL) / CASE WHEN total = 0 THEN 1 ELSE total END) DESC, user_name`,
		date)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanSnapshots(rows)
}

// BoardRange 取 [from, to] 区间内所有快照，返回 date -> 该天的快照列表（看板的近 7 天小格子用）。
func (s *store) BoardRange(from, to string) (map[string][]DaySnapshot, error) {
	rows, err := s.db.Query(`
		SELECT user_name, date, total, done, is_rest, streak, app_version,
		       tasks_json, note_gain, note_blocker, note_tomorrow, note_extra, uploaded_at
		FROM day_snapshots WHERE date >= ? AND date <= ?
		ORDER BY date, user_name`, from, to)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list, err := scanSnapshots(rows)
	if err != nil {
		return nil, err
	}
	out := map[string][]DaySnapshot{}
	for _, s := range list {
		out[s.Date] = append(out[s.Date], s)
	}
	return out, nil
}

// Users 列出出现过的所有昵称（看板要固定显示这 3 个人，即使某人今天没上传）。
func (s *store) Users() ([]string, error) {
	rows, err := s.db.Query(`SELECT DISTINCT user_name FROM day_snapshots ORDER BY user_name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

// LatestBefore 取某人 date 之前（严格早于）最近一次上传。
// 用于「今天没上传」的延续显示：拿他上一次的数据看看有没有还在周期内的周期任务。
func (s *store) LatestBefore(name, date string) (*DaySnapshot, error) {
	rows, err := s.db.Query(`
		SELECT user_name, date, total, done, is_rest, streak, app_version,
		       tasks_json, note_gain, note_blocker, note_tomorrow, note_extra, uploaded_at
		FROM day_snapshots WHERE user_name = ? AND date < ?
		ORDER BY date DESC LIMIT 1`, name, date)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list, err := scanSnapshots(rows)
	if err != nil || len(list) == 0 {
		return nil, err
	}
	return &list[0], nil
}

// ---------- 迁移 / 管理操作（改昵称、管理页纠错） ----------

// RenameUser 把 from 的全部数据迁到 to 名下。
// 同一天两边都有数据时取「上传时间较新」的那份；迁完 from 在库里彻底消失。
// 幂等：from 没有数据时是纯 no-op，重复调用结果一致（改昵称的自动迁移会重试）。
func (s *store) RenameUser(from, to string) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }() // 已提交后回滚是 no-op

	// to 已有数据的日期 -> 上传时间
	targets := map[string]int64{}
	rows, err := tx.Query(`SELECT date, uploaded_at FROM day_snapshots WHERE user_name = ?`, to)
	if err != nil {
		return 0, err
	}
	for rows.Next() {
		var d string
		var up int64
		if err := rows.Scan(&d, &up); err != nil {
			rows.Close()
			return 0, err
		}
		targets[d] = up
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}

	type srcRow struct {
		date string
		up   int64
	}
	var src []srcRow
	rows, err = tx.Query(`SELECT date, uploaded_at FROM day_snapshots WHERE user_name = ?`, from)
	if err != nil {
		return 0, err
	}
	for rows.Next() {
		var r srcRow
		if err := rows.Scan(&r.date, &r.up); err != nil {
			rows.Close()
			return 0, err
		}
		src = append(src, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}

	moved := 0
	for _, r := range src {
		if up, ok := targets[r.date]; ok {
			if r.up <= up {
				// 目标那份更新（或同刻）：丢掉 from 的这行
				if _, err := tx.Exec(
					`DELETE FROM day_snapshots WHERE user_name = ? AND date = ?`, from, r.date); err != nil {
					return 0, err
				}
				continue
			}
			// from 那份更新：先删 to 的旧行，再把 from 行改名过去
			if _, err := tx.Exec(
				`DELETE FROM day_snapshots WHERE user_name = ? AND date = ?`, to, r.date); err != nil {
				return 0, err
			}
		}
		if _, err := tx.Exec(
			`UPDATE day_snapshots SET user_name = ? WHERE user_name = ? AND date = ?`, to, from, r.date); err != nil {
			return 0, err
		}
		moved++
	}
	// 防御性清理：理论上上面已覆盖 from 的全部日期
	if _, err := tx.Exec(`DELETE FROM day_snapshots WHERE user_name = ?`, from); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return moved, nil
}

// AdminUserInfo 管理页「昵称列表」的一行。
type AdminUserInfo struct {
	Name       string `json:"name"`
	Days       int    `json:"days"`
	FirstDate  string `json:"first_date"`
	LastDate   string `json:"last_date"`
	LastUpload int64  `json:"last_upload"` // unix 秒
}

// AdminUsers 按昵称聚合出管理页需要的信息。
func (s *store) AdminUsers() ([]AdminUserInfo, error) {
	rows, err := s.db.Query(`
		SELECT user_name, COUNT(*), MIN(date), MAX(date), MAX(uploaded_at)
		FROM day_snapshots GROUP BY user_name ORDER BY user_name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AdminUserInfo
	for rows.Next() {
		var u AdminUserInfo
		if err := rows.Scan(&u.Name, &u.Days, &u.FirstDate, &u.LastDate, &u.LastUpload); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// SnapshotOf 取某人某天的快照（管理页查看用）；没有返回 nil。
func (s *store) SnapshotOf(name, date string) (*DaySnapshot, error) {
	rows, err := s.db.Query(`
		SELECT user_name, date, total, done, is_rest, streak, app_version,
		       tasks_json, note_gain, note_blocker, note_tomorrow, note_extra, uploaded_at
		FROM day_snapshots WHERE user_name = ? AND date = ?`, name, date)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list, err := scanSnapshots(rows)
	if err != nil || len(list) == 0 {
		return nil, err
	}
	return &list[0], nil
}

// DeleteUser 删除某人全部数据，返回删除行数。
func (s *store) DeleteUser(name string) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, err := s.db.Exec(`DELETE FROM day_snapshots WHERE user_name = ?`, name)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// DeleteDay 删除某人某天的快照，返回删除行数。
func (s *store) DeleteDay(name, date string) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, err := s.db.Exec(
		`DELETE FROM day_snapshots WHERE user_name = ? AND date = ?`, name, date)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// UpdateDayMeta 只改汇总字段（total/done/是否休息），任务列表与总结原样保留——
// 管理页纠错用。返回影响行数（0 = 这天没有数据）。
func (s *store) UpdateDayMeta(name, date string, total, done int, isRest bool) (int64, error) {
	rest := 0
	if isRest {
		rest = 1
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	res, err := s.db.Exec(`
		UPDATE day_snapshots SET total = ?, done = ?, is_rest = ?, uploaded_at = ?
		WHERE user_name = ? AND date = ?`,
		total, done, rest, time.Now().Unix(), name, date)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func scanSnapshots(rows *sql.Rows) ([]DaySnapshot, error) {
	var out []DaySnapshot
	for rows.Next() {
		var (
			s          DaySnapshot
			rest       int
			tasksRaw   string
			g, b, t, e string
		)
		if err := rows.Scan(&s.Name, &s.Date, &s.Total, &s.Done, &rest, &s.Streak,
			&s.AppVersion, &tasksRaw, &g, &b, &t, &e, &s.UploadedAt); err != nil {
			return nil, err
		}
		s.IsRest = rest == 1
		if err := json.Unmarshal([]byte(tasksRaw), &s.Tasks); err != nil {
			s.Tasks = nil // 坏数据不该让整块看板挂掉
		}
		if g != "" || b != "" || t != "" || e != "" {
			s.Note = &Note{Gain: g, Blocker: b, Tomorrow: t, Extra: e}
		}
		out = append(out, s)
	}
	return out, rows.Err()
}
