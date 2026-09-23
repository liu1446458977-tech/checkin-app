# checkin-server · 三人打卡看板后端

手机端（Flutter App）是**唯一数据源**，这个后端只做两件事：

1. **收**：`POST /api/day` 收下某人某天的完成快照；
2. **给**：`GET /api/board` 与 `GET /`（看板页面）把三个人的完成情况摊开。

**刻意不做**：双向同步、多端编辑、冲突合并、注册登录、找回密码。
身份就是**昵称**（App 里设置后不可修改），所以昵称本身即是硬性身份隔离。

---

## 一、接口

### `POST /api/day` —— 上传一天快照（同一天重复上传 = 覆盖）

```json
{
  "name": "博文",
  "date": "2026-09-19",
  "total": 3,
  "done": 2,
  "is_rest": false,
  "streak": 7,
  "app_version": "1.2.0+4",
  "tasks": [
    {"uuid": "u1", "name": "背单词",   "kind": "repeating", "done": true},
    {"uuid": "u2", "name": "瘦2斤",    "kind": "periodic",  "done": true, "schedule": "9月19日–9月29日"},
    {"uuid": "u3", "name": "交实验报告", "kind": "single",    "done": false}
  ],
  "note": {"gain": "…", "blocker": "…", "tomorrow": "…", "extra": "…"}
}
```

- `name` 必填 ≤32 字；`date` 必须 `YYYY-MM-DD`；`total/done` 范围 0~200；`tasks` ≤100 条；请求体 ≤256KB。
- `kind` 取值：`single`（一天的任务）/ `repeating`（每天重复）/ `periodic`（周期任务）。
- `note` 可省略。

### `GET /api/board?date=YYYY-MM-DD&days=7`

- `date` 省略 = 今天；`days=1`（默认）只返回当天，`days>1` 额外返回区间内每天的数据（看板近 7 天格子用）。
- 返回里带 `users`（历史上出现过的所有昵称），所以**某人今天没上传也占一张卡片**，一眼看出"谁没交"。

### `GET /api/health`

给监控/自检用，**不校验口令**。

### `GET /`

看板页面（纯静态 + 内联样式与脚本，**不引任何外部 CDN**，国内打开很快）。
页面首次遇到 401 会弹框让你输口令，存在浏览器 localStorage 里。

### 可选口令

启动时带 `-key=xxx`（或环境变量 `CHECKIN_KEY`）：所有 `/api/*`（除 health）都要带请求头
`X-Checkin-Key: xxx`。**不配就是不校验**——三人可信圈子够用，配上能挡掉陌生人扫端口。

---

## 二、构建

```bash
# 本机（Windows）自测用
go build -trimpath -ldflags "-s -w" -o dist/checkin-server.exe .

# 极客云（armv7l，32 位 ARM）—— 静态链接、零依赖，拷过去就能跑
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 \
  go build -trimpath -ldflags "-s -w" -o dist/checkin-server-linux-armv7 .
```

- 用的是 `modernc.org/sqlite`（**纯 Go 驱动**），所以交叉编译**不需要 cgo 工具链**——
  这是刻意的：换成 `mattn/go-sqlite3` 立刻要装 arm 交叉编译器，麻烦十倍。
- 产物约 11MB，`file` 显示 `ELF 32-bit LSB executable, ARM, EABI5, statically linked`。
- 若目标机是 `armv6l`（很老的设备），把 `GOARM=7` 改成 `GOARM=6`。
- 先确认架构：`uname -m` → `armv7l` 就是本文档这一套。

国内网络记得带代理环境变量：

```bash
export GOPROXY=https://goproxy.cn,direct
export GOSUMDB=sum.golang.google.cn
```

---

## 三、部署（极客云 / systemd）

```bash
# 1) 传二进制（在 Windows 上执行）
scp dist/checkin-server-linux-armv7 root@<服务器>:/opt/checkin/checkin-server

# 2) 服务器上
sudo mkdir -p /opt/checkin
sudo useradd -r -s /usr/sbin/nologin checkin || true
sudo chown -R checkin:checkin /opt/checkin
sudo chmod +x /opt/checkin/checkin-server

# 3) systemd
sudo cp deploy/checkin-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now checkin-server
sudo systemctl status checkin-server --no-pager

# 4) 自检
curl -s localhost:8787/api/health
```

数据库落在 `/opt/checkin/checkin.db`（WAL 模式）。**备份就是拷这一个文件**（连同 `-wal`/`-shm`）。

### 反向代理 + HTTPS（可选但推荐）

```nginx
location / {
    proxy_pass http://127.0.0.1:8787;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

用 `certbot` 签个证书；或者更省事：把域名挂在 Cloudflare 后面。
**注意**：走 HTTPS 时，App 里的服务器地址要写 `https://你的域名`。

### 防火墙

只放行 80/443（走反代）或你自选的端口；**别把 8787 直接暴露到公网**（除非配了 `-key`）。

---

## 四、测试

```bash
go vet ./...
go test ./... -v
```

覆盖：上传→看板往返、同日覆盖、多用户与"没上传也占卡片"、参数校验、非 JSON、方法不对、
共享口令（401/200）、健康检查免校验、看板页面能渲染。

---

## 五、以后要加东西时

- **加字段**：`day_snapshots` 上加列即可（`CREATE TABLE IF NOT EXISTS` + `ALTER TABLE ADD COLUMN`
  先 `PRAGMA table_info` 查一遍），别删旧列——和 App 侧同一套非破坏规矩。
- **加接口**：都放在 `routes()` 里，记得想清楚**要不要口令**。
- **要不要做双向同步**：想清楚再动手。目前手机是唯一数据源，服务器只是镜子；
  一旦允许"在网页上改数据并同步回手机"，就要处理冲突、时钟、删除语义——
  那是完全不同的复杂度，三人自用**不值得**。
