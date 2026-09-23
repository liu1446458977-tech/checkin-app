package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
)

// newTestServer 起一个用临时库的测试实例（不碰真数据）。
func newTestServer(t *testing.T, key string) (*server, *http.ServeMux) {
	t.Helper()
	st, err := openStore(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("开库失败: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	s := &server{store: st, key: key}
	mux := http.NewServeMux()
	s.routes(mux)
	return s, mux
}

func doJSON(t *testing.T, mux *http.ServeMux, method, path string, body any, key string) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatal(err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	if key != "" {
		req.Header.Set("X-Checkin-Key", key)
	}
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	return w
}

func sampleUpload(name, date string) DayUpload {
	return DayUpload{
		Name: name, Date: date, Total: 3, Done: 2, Streak: 5, AppVersion: "1.2.0",
		Tasks: []TaskItem{
			{UUID: "u1", Name: "背单词", Kind: "repeating", Done: true},
			{UUID: "u2", Name: "瘦2斤", Kind: "periodic", Done: true, Schedule: "9月19日–9月29日"},
			{UUID: "u3", Name: "交实验报告", Kind: "single", Done: false},
		},
		Note: &Note{Gain: "看完一章", Blocker: "困", Tomorrow: "早起", Extra: "无"},
	}
}

func TestUploadThenBoard(t *testing.T) {
	_, mux := newTestServer(t, "")

	w := doJSON(t, mux, http.MethodPost, "/api/day", sampleUpload("博文", "2026-09-19"), "")
	if w.Code != http.StatusOK {
		t.Fatalf("上传应 200，实际 %d：%s", w.Code, w.Body.String())
	}

	w = doJSON(t, mux, http.MethodGet, "/api/board?date=2026-09-19", nil, "")
	if w.Code != http.StatusOK {
		t.Fatalf("看板应 200，实际 %d", w.Code)
	}
	var got struct {
		Date  string        `json:"date"`
		Users []string      `json:"users"`
		Today []DaySnapshot `json:"today"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Date != "2026-09-19" || len(got.Today) != 1 {
		t.Fatalf("看板内容不对: %+v", got)
	}
	s := got.Today[0]
	if s.Name != "博文" || s.Total != 3 || s.Done != 2 || s.Streak != 5 {
		t.Fatalf("快照字段不对: %+v", s)
	}
	if len(s.Tasks) != 3 || s.Tasks[1].Schedule == "" {
		t.Fatalf("任务没存对: %+v", s.Tasks)
	}
	if s.Note == nil || s.Note.Gain != "看完一章" {
		t.Fatalf("睡前总结没存对: %+v", s.Note)
	}
}

func TestUpsertOverwritesSameDay(t *testing.T) {
	_, mux := newTestServer(t, "")
	doJSON(t, mux, http.MethodPost, "/api/day", sampleUpload("博文", "2026-09-19"), "")

	u := sampleUpload("博文", "2026-09-19")
	u.Done = 3
	u.Streak = 9
	doJSON(t, mux, http.MethodPost, "/api/day", u, "")

	w := doJSON(t, mux, http.MethodGet, "/api/board?date=2026-09-19", nil, "")
	var got struct {
		Today []DaySnapshot `json:"today"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &got)
	if len(got.Today) != 1 {
		t.Fatalf("同一天应只有一条记录，实际 %d 条", len(got.Today))
	}
	if got.Today[0].Done != 3 || got.Today[0].Streak != 9 {
		t.Fatalf("覆盖失败: %+v", got.Today[0])
	}
}

func TestThreeUsersVisibleEvenIfNotUploaded(t *testing.T) {
	_, mux := newTestServer(t, "")
	doJSON(t, mux, http.MethodPost, "/api/day", sampleUpload("博文", "2026-09-19"), "")
	doJSON(t, mux, http.MethodPost, "/api/day", sampleUpload("老王", "2026-09-18"), "")

	w := doJSON(t, mux, http.MethodGet, "/api/board?date=2026-09-19&days=7", nil, "")
	var got struct {
		Users []string                 `json:"users"`
		Today []DaySnapshot            `json:"today"`
		Days  []string                 `json:"days"`
		Range map[string][]DaySnapshot `json:"range"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Users) != 2 {
		t.Fatalf("应列出 2 个昵称，实际 %v", got.Users)
	}
	if len(got.Days) != 7 {
		t.Fatalf("应该给 7 天，实际 %d", len(got.Days))
	}
	if len(got.Range["2026-09-18"]) != 1 {
		t.Fatalf("区间里应有 9-18 老王的数据: %+v", got.Range)
	}
}

func TestValidation(t *testing.T) {
	_, mux := newTestServer(t, "")
	cases := []struct {
		name string
		body any
		code int
	}{
		{"空昵称", map[string]any{"name": "  ", "date": "2026-09-19"}, http.StatusBadRequest},
		{"日期格式错", map[string]any{"name": "博文", "date": "2026/09/19"}, http.StatusBadRequest},
		{"数字越界", map[string]any{"name": "博文", "date": "2026-09-19", "total": 999}, http.StatusBadRequest},
	}
	for _, c := range cases {
		if w := doJSON(t, mux, http.MethodPost, "/api/day", c.body, ""); w.Code != c.code {
			t.Errorf("%s: 期望 %d，实际 %d", c.name, c.code, w.Code)
		}
	}
	// 非 JSON
	req := httptest.NewRequest(http.MethodPost, "/api/day", bytes.NewBufferString("不是 json"))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("非 JSON 应 400，实际 %d", w.Code)
	}
	// 方法不对
	if w := doJSON(t, mux, http.MethodGet, "/api/day", nil, ""); w.Code != http.StatusMethodNotAllowed {
		t.Errorf("GET /api/day 应 405，实际 %d", w.Code)
	}
}

func TestSharedKey(t *testing.T) {
	_, mux := newTestServer(t, "s3cret")
	if w := doJSON(t, mux, http.MethodGet, "/api/board", nil, ""); w.Code != http.StatusUnauthorized {
		t.Fatalf("没带口令应 401，实际 %d", w.Code)
	}
	if w := doJSON(t, mux, http.MethodGet, "/api/board", nil, "wrong"); w.Code != http.StatusUnauthorized {
		t.Fatalf("口令错应 401，实际 %d", w.Code)
	}
	if w := doJSON(t, mux, http.MethodGet, "/api/board", nil, "s3cret"); w.Code != http.StatusOK {
		t.Fatalf("口令对应 200，实际 %d", w.Code)
	}
	// 健康检查不需要口令（方便监控）
	if w := doJSON(t, mux, http.MethodGet, "/api/health", nil, ""); w.Code != http.StatusOK {
		t.Fatalf("健康检查应 200，实际 %d", w.Code)
	}
}

func TestBoardPageServed(t *testing.T) {
	_, mux := newTestServer(t, "")
	w := doJSON(t, mux, http.MethodGet, "/", nil, "")
	if w.Code != http.StatusOK || !bytes.Contains(w.Body.Bytes(), []byte("每日打卡 · 看板")) {
		t.Fatalf("看板页面没出来：%d", w.Code)
	}
}
