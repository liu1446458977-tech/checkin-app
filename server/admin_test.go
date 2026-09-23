package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// ---------- 改昵称迁移（/api/rename） ----------

func uploadFor(t *testing.T, mux *http.ServeMux, name, date string, done int) {
	t.Helper()
	u := DayUpload{
		Name: name, Date: date, Total: 3, Done: done, Streak: 1,
		Tasks: []TaskItem{{UUID: "x1", Name: "背单词", Kind: "repeating", Done: done > 0}},
	}
	if w := doJSON(t, mux, http.MethodPost, "/api/day", u, ""); w.Code != http.StatusOK {
		t.Fatalf("上传失败 %d：%s", w.Code, w.Body.String())
	}
}

func doRename(t *testing.T, mux *http.ServeMux, from, to string) (int, int) {
	t.Helper()
	w := doJSON(t, mux, http.MethodPost, "/api/rename",
		map[string]string{"from": from, "to": to}, "")
	var got struct {
		Ok    bool `json:"ok"`
		Moved int  `json:"moved"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &got)
	return w.Code, got.Moved
}

func TestRenameMovesAllData(t *testing.T) {
	_, mux := newTestServer(t, "")
	uploadFor(t, mux, "老名字", "2026-09-18", 2)
	uploadFor(t, mux, "老名字", "2026-09-19", 3)

	if code, moved := doRename(t, mux, "老名字", "新名字"); code != 200 || moved != 2 {
		t.Fatalf("迁移应 200/moved=2，实际 %d/%d", code, moved)
	}

	users, _ := boardOn(t, mux, "2026-09-19")
	if len(users) != 1 || users[0] != "新名字" {
		t.Fatalf("旧名应彻底消失、只剩新名：%v", users)
	}
	_, today := boardOn(t, mux, "2026-09-19")
	if len(today) != 1 || today[0].Name != "新名字" || today[0].Done != 3 {
		t.Fatalf("迁移后的数据不对：%+v", today)
	}
}

func TestRenameConflictKeepsNewer(t *testing.T) {
	s, mux := newTestServer(t, "")
	uploadFor(t, mux, "A", "2026-09-19", 1)
	uploadFor(t, mux, "B", "2026-09-19", 2)

	// 情况一：A（被迁走的）更新 → 应保留 A 那份（done=1）
	if _, err := s.store.db.Exec(
		`UPDATE day_snapshots SET uploaded_at = uploaded_at + 100 WHERE user_name = 'A'`); err != nil {
		t.Fatal(err)
	}
	if code, _ := doRename(t, mux, "A", "B"); code != 200 {
		t.Fatalf("迁移失败 %d", code)
	}
	snap, err := s.store.SnapshotOf("B", "2026-09-19")
	if err != nil || snap == nil || snap.Done != 1 {
		t.Fatalf("应保留更新的 A 那份（done=1）：%+v err=%v", snap, err)
	}

	// 情况二：目标（B）更新 → A 那份应被丢弃
	uploadFor(t, mux, "A2", "2026-09-20", 5)
	if _, err := s.store.db.Exec(
		`UPDATE day_snapshots SET uploaded_at = uploaded_at - 100 WHERE user_name = 'A2'`); err != nil {
		t.Fatal(err)
	}
	// B 在 9-20 没有数据，先造一条更晚的
	uploadFor(t, mux, "B", "2026-09-20", 7)
	if code, _ := doRename(t, mux, "A2", "B"); code != 200 {
		t.Fatalf("迁移失败 %d", code)
	}
	snap2, err := s.store.SnapshotOf("B", "2026-09-20")
	if err != nil || snap2 == nil || snap2.Done != 7 {
		t.Fatalf("B 更新的那份应保留（done=7）：%+v err=%v", snap2, err)
	}
	if _, err := s.store.SnapshotOf("A2", "2026-09-20"); err != nil {
		t.Fatal(err)
	}
	users, _ := boardOn(t, mux, "2026-09-20")
	if len(users) != 1 {
		t.Fatalf("A2 应已消失：%v", users)
	}
}

func TestRenameNoopAndIdempotent(t *testing.T) {
	_, mux := newTestServer(t, "")
	// from 不存在 → 成功且 moved=0；重复调用结果一致
	if code, moved := doRename(t, mux, "幽灵", "新名"); code != 200 || moved != 0 {
		t.Fatalf("空迁移应 200/0，实际 %d/%d", code, moved)
	}
	uploadFor(t, mux, "甲", "2026-09-19", 2)
	if code, moved := doRename(t, mux, "甲", "乙"); code != 200 || moved != 1 {
		t.Fatalf("第一次应搬 1 天，实际 %d/%d", code, moved)
	}
	if code, moved := doRename(t, mux, "甲", "乙"); code != 200 || moved != 0 {
		t.Fatalf("第二次应幂等（0），实际 %d/%d", code, moved)
	}
	// 改成同名 → 直接成功
	if code, moved := doRename(t, mux, "乙", "乙"); code != 200 || moved != 0 {
		t.Fatalf("同名应 200/0，实际 %d/%d", code, moved)
	}
}

// ---------- 管理后台 ----------

func doAdmin(t *testing.T, mux *http.ServeMux, method, path string, body any, admin string) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatal(err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	if admin != "" {
		req.Header.Set("X-Checkin-Admin", admin)
	}
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	return w
}

func TestAdminDisabledWithoutToken(t *testing.T) {
	_, mux := newTestServer(t, "")
	if w := doAdmin(t, mux, http.MethodGet, "/admin", nil, ""); w.Code != http.StatusNotFound {
		t.Fatalf("未配口令时 /admin 应 404，实际 %d", w.Code)
	}
	if w := doAdmin(t, mux, http.MethodGet, "/api/admin/users", nil, ""); w.Code != http.StatusNotFound {
		t.Fatalf("未配口令时管理接口应 404，实际 %d", w.Code)
	}
}

func TestAdminAuthAndOps(t *testing.T) {
	s, mux := newTestServer(t, "")
	s.adminToken = "t0p-secret"

	// 鉴权：无头/错口令 401，正确 200
	if w := doAdmin(t, mux, http.MethodGet, "/api/admin/users", nil, ""); w.Code != http.StatusUnauthorized {
		t.Fatalf("无头应 401，实际 %d", w.Code)
	}
	if w := doAdmin(t, mux, http.MethodGet, "/api/admin/users", nil, "wrong"); w.Code != http.StatusUnauthorized {
		t.Fatalf("错口令应 401，实际 %d", w.Code)
	}
	if w := doAdmin(t, mux, http.MethodGet, "/api/admin/users", nil, "t0p-secret"); w.Code != http.StatusOK {
		t.Fatalf("对口令应 200，实际 %d", w.Code)
	}
	// 管理页壳可打开
	if w := doAdmin(t, mux, http.MethodGet, "/admin", nil, ""); w.Code != http.StatusOK {
		t.Fatalf("/admin 页面应 200，实际 %d", w.Code)
	}

	// 造数据 → users 列表
	uploadFor(t, mux, "博文", "2026-09-19", 2)
	uploadFor(t, mux, "博文", "2026-09-20", 3)
	w := doAdmin(t, mux, http.MethodGet, "/api/admin/users", nil, "t0p-secret")
	var usersResp struct {
		Users []AdminUserInfo `json:"users"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &usersResp); err != nil {
		t.Fatal(err)
	}
	if len(usersResp.Users) != 1 || usersResp.Users[0].Name != "博文" || usersResp.Users[0].Days != 2 {
		t.Fatalf("users 列表不对：%+v", usersResp.Users)
	}

	// 单日查询 + 改数字
	if w := doAdmin(t, mux, http.MethodGet, "/api/admin/day?name=博文&date=2026-09-19", nil, "t0p-secret"); w.Code != http.StatusOK {
		t.Fatalf("单日查询应 200，实际 %d", w.Code)
	}
	if w := doAdmin(t, mux, http.MethodPost, "/api/admin/save_day",
		map[string]any{"name": "博文", "date": "2026-09-19", "total": 5, "done": 5, "is_rest": false}, "t0p-secret"); w.Code != http.StatusOK {
		t.Fatalf("保存应 200，实际 %d %s", w.Code, w.Body.String())
	}
	snap, err := s.store.SnapshotOf("博文", "2026-09-19")
	if err != nil || snap == nil || snap.Total != 5 || snap.Done != 5 {
		t.Fatalf("保存后数据不对：%+v err=%v", snap, err)
	}
	// 不存在的日期 → 404
	if w := doAdmin(t, mux, http.MethodPost, "/api/admin/save_day",
		map[string]any{"name": "博文", "date": "2026-01-01", "total": 1, "done": 1}, "t0p-secret"); w.Code != http.StatusNotFound {
		t.Fatalf("不存在日期应 404，实际 %d", w.Code)
	}

	// 删单日 → 再查 404
	if w := doAdmin(t, mux, http.MethodPost, "/api/admin/delete_day",
		map[string]any{"name": "博文", "date": "2026-09-19"}, "t0p-secret"); w.Code != http.StatusOK {
		t.Fatalf("删单日应 200，实际 %d", w.Code)
	}
	if w := doAdmin(t, mux, http.MethodGet, "/api/admin/day?name=博文&date=2026-09-19", nil, "t0p-secret"); w.Code != http.StatusNotFound {
		t.Fatalf("删后查询应 404，实际 %d", w.Code)
	}

	// 删昵称 → users 为空
	if w := doAdmin(t, mux, http.MethodPost, "/api/admin/delete_user",
		map[string]any{"name": "博文"}, "t0p-secret"); w.Code != http.StatusOK {
		t.Fatalf("删昵称应 200，实际 %d", w.Code)
	}
	w = doAdmin(t, mux, http.MethodGet, "/api/admin/users", nil, "t0p-secret")
	usersResp.Users = nil
	_ = json.Unmarshal(w.Body.Bytes(), &usersResp)
	if len(usersResp.Users) != 0 {
		t.Fatalf("删昵称后应无数据：%+v", usersResp.Users)
	}
}
