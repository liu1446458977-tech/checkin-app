package main

import (
	"crypto/subtle"
	"embed"
	"encoding/json"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"
)

//go:embed board.html
var boardPage embed.FS

//go:embed admin.html
var adminPageFS embed.FS

// TaskItem 是上传的单个任务（App 的 Task 在当天的呈现）。
type TaskItem struct {
	UUID     string `json:"uuid"`
	Name     string `json:"name"`
	Kind     string `json:"kind"`               // single | repeating | periodic
	Done     bool   `json:"done"`               // 当天是否完成
	Schedule string `json:"schedule,omitempty"` // 周期任务的区间文案，如 9月19日–9月29日
	// 周期任务的结构化起止日（YYYY-MM-DD）。「没上传的日子延续显示」靠它判断，
	// 老版本 App 没带这两个字段时该任务不参与延续（宁缺毋滥）。
	Start string `json:"start,omitempty"`
	End   string `json:"end,omitempty"`
}

// Note 是当天的睡前总结（可为空）。
type Note struct {
	Gain     string `json:"gain"`
	Blocker  string `json:"blocker"`
	Tomorrow string `json:"tomorrow"`
	Extra    string `json:"extra"`
}

// DayUpload 是 App 上传的一天快照。
// 注意：这里**没有用户 ID / token**——身份就是 name（App 里设置后不可修改）。
// 这是刻意的：三人可信圈子里，"不可改的昵称"就足够做硬性隔离，
// 加上共享口令（-key）可以再挡一层陌生人。
type DayUpload struct {
	Name       string     `json:"name"`
	Date       string     `json:"date"` // YYYY-MM-DD
	Total      int        `json:"total"`
	Done       int        `json:"done"`
	IsRest     bool       `json:"is_rest"`
	Streak     int        `json:"streak"`
	Tasks      []TaskItem `json:"tasks"`
	Note       *Note      `json:"note,omitempty"`
	AppVersion string     `json:"app_version,omitempty"`
}

type server struct {
	store *store
	key   string
	// adminToken 为空时 /admin 与管理接口一律 404——「没配置 = 不存在」，
	// 默认不给任何攻击面；配置后管理接口要带 X-Checkin-Admin 头。
	adminToken string
}

var dateRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)

func (s *server) routes(mux *http.ServeMux) {
	mux.HandleFunc("/api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "time": time.Now().Format(time.RFC3339)})
	})
	mux.HandleFunc("/api/day", s.withAuth(s.handleDay))
	mux.HandleFunc("/api/board", s.withAuth(s.handleBoard))
	mux.HandleFunc("/api/rename", s.withAuth(s.handleRename))
	mux.HandleFunc("/admin", s.handleAdminPage)
	mux.HandleFunc("/api/admin/users", s.withAdmin(s.handleAdminUsers))
	mux.HandleFunc("/api/admin/rename", s.withAdmin(s.handleAdminRename))
	mux.HandleFunc("/api/admin/delete_user", s.withAdmin(s.handleAdminDeleteUser))
	mux.HandleFunc("/api/admin/day", s.withAdmin(s.handleAdminDay))
	mux.HandleFunc("/api/admin/save_day", s.withAdmin(s.handleAdminSaveDay))
	mux.HandleFunc("/api/admin/delete_day", s.withAdmin(s.handleAdminDeleteDay))
	mux.HandleFunc("/", s.handleBoardPage)
}

// withAuth 校验可选的共享口令。没配 key 就全部放行（三人自用最省事）。
func (s *server) withAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.key != "" {
			got := r.Header.Get("X-Checkin-Key")
			// 常量时间比较，避免时序侧信道（虽然这里没人攻击，但两行代码的事）
			if subtle.ConstantTimeCompare([]byte(got), []byte(s.key)) != 1 {
				writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "口令不对"})
				return
			}
		}
		next(w, r)
	}
}

// withAdmin 管理接口的鉴权。管理口令没配置时全部 404（页面和接口一起消失）。
func (s *server) withAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.adminToken == "" {
			http.NotFound(w, r)
			return
		}
		got := r.Header.Get("X-Checkin-Admin")
		if subtle.ConstantTimeCompare([]byte(got), []byte(s.adminToken)) != 1 {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "管理口令不对"})
			return
		}
		next(w, r)
	}
}

// validName 昵称校验：非空且不超过 32 个字（与 /api/day 同一口径）。
func validName(n string) bool { return n != "" && len([]rune(n)) <= 32 }

// ---------- 改昵称迁移（App 自动调用，与 /api/day 同一信任级别） ----------

type renameReq struct {
	From string `json:"from"`
	To   string `json:"to"`
}

// handleRename 把 from 的全部数据迁到 to 名下（同日冲突取上传时间较新的）。
// App 在「重置昵称 → 重新设置」后自动调用；幂等，from 不存在时直接成功。
func (s *server) handleRename(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "只接受 POST"})
		return
	}
	var req renameReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "请求体不是合法 JSON"})
		return
	}
	req.From = strings.TrimSpace(req.From)
	req.To = strings.TrimSpace(req.To)
	if !validName(req.From) || !validName(req.To) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "from/to 必填且不超过 32 个字"})
		return
	}
	if req.From == req.To {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "moved": 0})
		return
	}
	moved, err := s.store.RenameUser(req.From, req.To)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "迁移失败"})
		return
	}
	log.Printf("昵称迁移: %s → %s（搬走 %d 天）", req.From, req.To, moved)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "moved": moved})
}

// ---------- 管理后台（/admin 页面 + /api/admin/* 接口） ----------

func (s *server) handleAdminPage(w http.ResponseWriter, r *http.Request) {
	if s.adminToken == "" {
		http.NotFound(w, r)
		return
	}
	b, err := adminPageFS.ReadFile("admin.html")
	if err != nil {
		http.Error(w, "页面缺失", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(b)
}

func (s *server) handleAdminUsers(w http.ResponseWriter, r *http.Request) {
	users, err := s.store.AdminUsers()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "读取失败"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": users})
}

// handleAdminRename 与 /api/rename 同一套逻辑（管理页走管理鉴权）。
func (s *server) handleAdminRename(w http.ResponseWriter, r *http.Request) {
	s.handleRename(w, r)
}

func (s *server) handleAdminDeleteUser(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "只接受 POST"})
		return
	}
	var req struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "请求体不是合法 JSON"})
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	if !validName(req.Name) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "name 必填"})
		return
	}
	n, err := s.store.DeleteUser(req.Name)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "删除失败"})
		return
	}
	log.Printf("管理页：删除昵称 %s（%d 天数据）", req.Name, n)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "deleted": n})
}

func (s *server) handleAdminDay(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimSpace(r.URL.Query().Get("name"))
	date := strings.TrimSpace(r.URL.Query().Get("date"))
	if !validName(name) || !dateRe.MatchString(date) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "name/date 不合法"})
		return
	}
	snap, err := s.store.SnapshotOf(name, date)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "读取失败"})
		return
	}
	if snap == nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "这天没有数据"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"snapshot": snap})
}

func (s *server) handleAdminSaveDay(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "只接受 POST"})
		return
	}
	var req struct {
		Name   string `json:"name"`
		Date   string `json:"date"`
		Total  int    `json:"total"`
		Done   int    `json:"done"`
		IsRest bool   `json:"is_rest"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "请求体不是合法 JSON"})
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	if !validName(req.Name) || !dateRe.MatchString(req.Date) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "name/date 不合法"})
		return
	}
	if req.Total < 0 || req.Done < 0 || req.Total > 200 || req.Done > 200 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "total/done 超出合理范围"})
		return
	}
	affected, err := s.store.UpdateDayMeta(req.Name, req.Date, req.Total, req.Done, req.IsRest)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "保存失败"})
		return
	}
	if affected == 0 {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "这天没有数据"})
		return
	}
	log.Printf("管理页：修改 %s %s → %d/%d rest=%v", req.Name, req.Date, req.Done, req.Total, req.IsRest)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleAdminDeleteDay(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "只接受 POST"})
		return
	}
	var req struct {
		Name string `json:"name"`
		Date string `json:"date"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "请求体不是合法 JSON"})
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	if !validName(req.Name) || !dateRe.MatchString(req.Date) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "name/date 不合法"})
		return
	}
	n, err := s.store.DeleteDay(req.Name, req.Date)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "删除失败"})
		return
	}
	if n == 0 {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "这天没有数据"})
		return
	}
	log.Printf("管理页：删除 %s %s 的快照", req.Name, req.Date)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "deleted": n})
}

// handleDay 接收一次上传（同一天重复上传 = 覆盖）。
func (s *server) handleDay(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "只接受 POST"})
		return
	}
	var u DayUpload
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256<<10)) // 一次上传不该超过 256KB
	if err := dec.Decode(&u); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "请求体不是合法 JSON: " + err.Error()})
		return
	}
	u.Name = strings.TrimSpace(u.Name)
	if u.Name == "" || len([]rune(u.Name)) > 32 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "name 必填且不超过 32 个字"})
		return
	}
	if !dateRe.MatchString(u.Date) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "date 必须是 YYYY-MM-DD"})
		return
	}
	if u.Total < 0 || u.Done < 0 || u.Total > 200 || u.Done > 200 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "total/done 超出合理范围"})
		return
	}
	if len(u.Tasks) > 100 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "一天的任务不该超过 100 条"})
		return
	}
	if err := s.store.UpsertDay(u); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "写入失败"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "date": u.Date, "name": u.Name})
}

// handleBoard 返回看板数据。
//
//	/api/board            当天
//	/api/board?date=...   指定日期
//	/api/board?days=7     从指定日期(默认今天)往前 7 天
func (s *server) handleBoard(w http.ResponseWriter, r *http.Request) {
	date := r.URL.Query().Get("date")
	if date == "" {
		date = time.Now().Format("2006-01-02")
	}
	if !dateRe.MatchString(date) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "date 必须是 YYYY-MM-DD"})
		return
	}
	days := 1
	if v := r.URL.Query().Get("days"); v != "" {
		if n := atoiSafe(v); n >= 1 && n <= 60 {
			days = n
		}
	}

	users, err := s.store.Users()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "读取用户失败"})
		return
	}
	today, err := s.store.BoardOn(date)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "读取看板失败"})
		return
	}
	today = s.appendCarried(users, date, today)

	dayList := []string{}
	if days > 1 {
		end, err := time.Parse("2006-01-02", date)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "date 解析失败"})
			return
		}
		start := end.AddDate(0, 0, -(days - 1))
		byDate, err := s.store.BoardRange(start.Format("2006-01-02"), date)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "读取区间失败"})
			return
		}
		for i := 0; i < days; i++ {
			dayList = append(dayList, start.AddDate(0, 0, i).Format("2006-01-02"))
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"date": date, "users": users, "today": today,
			"days": dayList, "range": byDate,
		})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"date": date, "users": users, "today": today})
}

// appendCarried 为「今天没上传」的每个人补一张延续卡：
// 从上一次上传里挑出还在周期内（start <= date <= end）的周期任务，
// 让他即使几天没打开 App，看板上也一直看得到正在进行的长期目标；
// 任务完成（done）或周期结束（date > end）后自然消失。
func (s *server) appendCarried(users []string, date string, today []DaySnapshot) []DaySnapshot {
	seen := map[string]bool{}
	for _, t := range today {
		seen[t.Name] = true
	}
	for _, name := range users {
		if seen[name] {
			continue // 今天有真实上传，不需要延续
		}
		last, err := s.store.LatestBefore(name, date)
		if err != nil || last == nil {
			continue
		}
		var inPeriod []TaskItem
		for _, t := range last.Tasks {
			if t.Kind != "periodic" || t.Start == "" || t.End == "" {
				continue
			}
			if t.Start <= date && date <= t.End { // YYYY-MM-DD 字典序即日期序
				inPeriod = append(inPeriod, t)
			}
		}
		if len(inPeriod) == 0 {
			continue
		}
		done := 0
		for _, t := range inPeriod {
			if t.Done {
				done++
			}
		}
		today = append(today, DaySnapshot{
			Name: name, Date: date,
			Total: len(inPeriod), Done: done,
			Tasks:   inPeriod,
			Carried: true, LastSync: last.Date,
		})
	}
	return today
}

func (s *server) handleBoardPage(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	b, err := boardPage.ReadFile("board.html")
	if err != nil {
		http.Error(w, "页面缺失", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(b)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func atoiSafe(s string) int {
	n := 0
	for _, r := range s {
		if r < '0' || r > '9' {
			return -1
		}
		n = n*10 + int(r-'0')
		if n > 1000 {
			return -1
		}
	}
	return n
}
