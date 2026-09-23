package main

import (
	"encoding/json"
	"net/http"
	"testing"
)

// 周期任务的「延续显示」：人几天不打开 App，看板上也要一直看得到
// 他进行中的周期任务，直到任务完成或周期结束。
//
// 语义要点（对应用户需求）：
//   1) 没上传 + 周期任务在周期内 → 出现延续卡（carried=true + last_sync）
//   2) 周期结束后 → 消失
//   3) 上次同步时已完成的周期任务 → 仍然显示（✓ 状态），直到周期结束
//   4) 老版本 App（没带 start/end）→ 不参与延续（宁缺毋滥）
//   5) 当天有真实上传 → 用真实数据，不延续

func uploadWithPeriodic(t *testing.T, mux *http.ServeMux, name, date string, done bool, start, end string) {
	t.Helper()
	u := DayUpload{
		Name: name, Date: date, Total: 2, Done: 1, Streak: 3,
		Tasks: []TaskItem{
			{UUID: "p1", Name: "跟着视频练口语", Kind: "periodic", Done: done, Schedule: "9月18日–9月28日", Start: start, End: end},
			{UUID: "s1", Name: "临时杂事", Kind: "single", Done: false},
		},
	}
	w := doJSON(t, mux, http.MethodPost, "/api/day", u, "")
	if w.Code != http.StatusOK {
		t.Fatalf("上传失败: %d %s", w.Code, w.Body.String())
	}
}

func boardOn(t *testing.T, mux *http.ServeMux, date string) ([]string, []DaySnapshot) {
	t.Helper()
	w := doJSON(t, mux, http.MethodGet, "/api/board?date="+date, nil, "")
	if w.Code != http.StatusOK {
		t.Fatalf("看板应 200，实际 %d", w.Code)
	}
	var got struct {
		Users []string      `json:"users"`
		Today []DaySnapshot `json:"today"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	return got.Users, got.Today
}

func TestCarriedWhenNoUpload(t *testing.T) {
	_, mux := newTestServer(t, "")
	// 9-19 上传过（周期任务 9/18–9/28，未完成）；9-21 没打开 App
	uploadWithPeriodic(t, mux, "博文", "2026-09-19", false, "2026-09-18", "2026-09-28")

	users, today := boardOn(t, mux, "2026-09-21")
	if len(today) != 1 {
		t.Fatalf("应有一张延续卡，实际 %d 张：%+v", len(today), today)
	}
	s := today[0]
	if s.Name != "博文" || !s.Carried {
		t.Fatalf("应是博文的延续卡: %+v", s)
	}
	if s.LastSync != "2026-09-19" {
		t.Fatalf("last_sync 应为 9-19，实际 %q", s.LastSync)
	}
	if len(s.Tasks) != 1 || s.Tasks[0].Name != "跟着视频练口语" {
		t.Fatalf("延续卡应只含周期内的周期任务: %+v", s.Tasks)
	}
	if s.Tasks[0].Done {
		t.Fatalf("上次同步时未完成，延续卡应显示未完成")
	}
	if len(users) != 1 || users[0] != "博文" {
		t.Fatalf("users 里也要有博文: %v", users)
	}
}

func TestCarriedShowsDoneStateUntilPeriodEnd(t *testing.T) {
	_, mux := newTestServer(t, "")
	// 9-19 就已经完成任务（完成一次即达成）
	uploadWithPeriodic(t, mux, "博文", "2026-09-19", true, "2026-09-18", "2026-09-28")

	_, today := boardOn(t, mux, "2026-09-25")
	if len(today) != 1 || !today[0].Carried {
		t.Fatalf("周期结束前都应显示延续卡: %+v", today)
	}
	if !today[0].Tasks[0].Done {
		t.Fatalf("任务已完成，延续卡应显示 ✓ 状态")
	}
}

func TestCarriedDisappearsAfterPeriodEnd(t *testing.T) {
	_, mux := newTestServer(t, "")
	uploadWithPeriodic(t, mux, "博文", "2026-09-19", false, "2026-09-18", "2026-09-28")

	_, today := boardOn(t, mux, "2026-09-29") // 周期结束的第二天
	if len(today) != 0 {
		t.Fatalf("周期结束后不应再延续: %+v", today)
	}
}

func TestNoCarryWithoutDates(t *testing.T) {
	_, mux := newTestServer(t, "")
	// 老版本 App：periodic 但没有 start/end → 不参与延续
	u := sampleUpload("博文", "2026-09-19")
	w := doJSON(t, mux, http.MethodPost, "/api/day", u, "")
	if w.Code != http.StatusOK {
		t.Fatal(w.Body.String())
	}
	_, today := boardOn(t, mux, "2026-09-21")
	if len(today) != 0 {
		t.Fatalf("没带起止日的旧数据不应延续: %+v", today)
	}
}

func TestRealUploadWinsOverCarry(t *testing.T) {
	_, mux := newTestServer(t, "")
	uploadWithPeriodic(t, mux, "博文", "2026-09-19", false, "2026-09-18", "2026-09-28")
	uploadWithPeriodic(t, mux, "博文", "2026-09-21", true, "2026-09-18", "2026-09-28")

	_, today := boardOn(t, mux, "2026-09-21")
	if len(today) != 1 {
		t.Fatalf("应只有一条真实记录: %+v", today)
	}
	if today[0].Carried {
		t.Fatalf("当天有真实上传时不应标记为延续")
	}
	if len(today[0].Tasks) != 2 {
		t.Fatalf("真实上传应包含全部任务: %+v", today[0].Tasks)
	}
}
