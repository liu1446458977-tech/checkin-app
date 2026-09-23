// checkin-server：三人打卡看板后端。
//
// 设计取舍（刻意选的，改之前先看注释）：
//   - **只做「上传 + 看板」单向数据流**：手机是唯一数据源，服务器只是给别人看的镜子。
//     不做双向同步、不做多端编辑、不做冲突合并——那是另一个量级的复杂度。
//   - **身份 = 昵称**：App 里设置后不可修改，所以昵称本身就是硬性身份隔离。
//     不搞注册 / 登录 / 找回密码 / 邮箱验证。
//   - **SQLite 单文件**，用 modernc.org/sqlite（纯 Go 驱动）：
//     交叉编译到 armv7l 不需要 cgo 工具链，一条命令出静态二进制。
//   - 除标准库外只依赖这一个驱动，服务器上零运行时依赖。
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

type config struct {
	addr   string // 监听地址，如 :8787
	dbPath string // SQLite 文件路径
	key    string // 可选的共享口令；为空表示不校验（三人可信圈子够用）
	admin  string // 可选管理口令；为空时 /admin 与管理接口一律 404（没配置 = 不存在）
}

func main() {
	cfg := config{}
	flag.StringVar(&cfg.addr, "addr", ":8787", "监听地址")
	flag.StringVar(&cfg.dbPath, "db", "checkin.db", "SQLite 数据库路径")
	flag.StringVar(&cfg.key, "key", os.Getenv("CHECKIN_KEY"), "可选共享口令（请求头 X-Checkin-Key）")
	flag.StringVar(&cfg.admin, "admin", os.Getenv("CHECKIN_ADMIN_TOKEN"),
		"可选管理口令（/admin 后台，请求头 X-Checkin-Admin）；不配则管理功能整体关闭")
	flag.Parse()

	st, err := openStore(cfg.dbPath)
	if err != nil {
		log.Fatalf("打开数据库失败: %v", err)
	}
	defer st.Close()

	mux := http.NewServeMux()
	srv := &server{store: st, key: cfg.key, adminToken: cfg.admin}
	srv.routes(mux)

	httpSrv := &http.Server{
		Addr:              cfg.addr,
		Handler:           logRequests(mux),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// 优雅退出：收到 SIGINT/SIGTERM 时把在途请求处理完再关，别把数据写坏。
	done := make(chan struct{})
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
		<-sig
		log.Println("收到退出信号，正在优雅关闭…")
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := httpSrv.Shutdown(ctx); err != nil {
			log.Printf("关闭出错: %v", err)
		}
		close(done)
	}()

	log.Printf("checkin-server 启动：addr=%s db=%s 口令校验=%v 管理页=%v",
		cfg.addr, cfg.dbPath, cfg.key != "", cfg.admin != "")
	if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("监听失败: %v", err)
	}
	<-done
	log.Println("已退出")
}

// logRequests 只记一行摘要，方便 systemd/journal 里排查；不记请求体（里面是私人内容）。
func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &statusWriter{ResponseWriter: w, code: 200}
		next.ServeHTTP(rw, r)
		log.Printf("%s %s %d %s", r.Method, r.URL.Path, rw.code, time.Since(start).Round(time.Millisecond))
	})
}

type statusWriter struct {
	http.ResponseWriter
	code int
}

func (w *statusWriter) WriteHeader(code int) {
	w.code = code
	w.ResponseWriter.WriteHeader(code)
}
