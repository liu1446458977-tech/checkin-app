# 部署到 1Panel（armv7l / Debian）——照着做，约 5 分钟

> 目标机实测信息：Debian、内核 `6.12.28-current-meson`、`armv7l`、4 核 / 981MB 内存 / 剩余 2.2GB 磁盘。
> **22 端口（SSH）不通**，所以全部走 1Panel 的「文件」+「终端」，不需要 SSH。

---

## 第 0 步：拿到二进制

在这台 Windows 上已经编译好了（**静态链接、零依赖**，`file` 显示
`ELF 32-bit LSB executable, ARM, EABI5, statically linked`）：

```
D:\checkin\checkin_app\server\dist\checkin-server-linux-armv7   （11MB）
```

> 以后改了后端代码，双击 `server\build_arm.cmd` 重新生成（它会先跑 vet + test）。

---

## 第 1 步：上传（1Panel → 系统 → 文件）

1. 左侧「系统」→「文件」
2. 地址栏进到 `/opt`，**新建目录** `checkin`
3. 进入 `/opt/checkin`，点「上传」→ 把这个文件传上去
4. 传完在文件上右键 →「权限」→ 确认可执行（或在下一步用命令 chmod，都一样）

## 第 2 步：装成系统服务（1Panel → 系统 → 终端）

把下面**整段**粘进网页终端，回车（**不设口令**，谁打开链接都能看）：

```bash
set -e
mkdir -p /opt/checkin
chmod +x /opt/checkin/checkin-server

cat > /etc/systemd/system/checkin-server.service <<'EOF'
[Unit]
Description=checkin-server 三人打卡看板
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/checkin
ExecStart=/opt/checkin/checkin-server -addr 0.0.0.0:8787 -db /opt/checkin/checkin.db
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now checkin-server
sleep 1
systemctl --no-pager --full status checkin-server | head -12
echo "---- 自检 ----"
curl -s -m 5 http://127.0.0.1:8787/api/health && echo || echo "自检失败"
```

看到 `{"ok":true,...}` 就成了。

> `User=root` 是为了省事；想更严格就 `useradd -r checkin` 并改 `User=checkin`
> + `chown -R checkin:checkin /opt/checkin`。

### 以后想加口令（不是必须的）

口令只防"陌生人扫端口"，三人自用**可以先不加**。要加的时候：

```bash
sed -i 's|-db /opt/checkin/checkin.db|-db /opt/checkin/checkin.db -key 你的口令|' \
  /etc/systemd/system/checkin-server.service
systemctl daemon-reload && systemctl restart checkin-server
```

改完在 App 的「设置 → 看板 → 共享口令」里填一样的值；看板网页会弹框让你输。

## 第 3 步：放行端口

1. **1Panel → 系统 → 防火墙**：放行 TCP `8787`（如果面板里开了防火墙）
2. **云服务商控制台的安全组**：同样放行 `TCP 8787`（这一步在 1Panel 里做不了，
   要去你买服务器的地方点）

验证（在你自己电脑浏览器直接开）：

```
http://glk0108.site:8787/          ← 看板页面
http://glk0108.site:8787/api/health
```

看到看板页面（此时还没有数据，显示"还没有人上传过"）就说明部署完成。

## 第 4 步：让手机开始上传

App **1.2.1** 出包后（正在做），在手机里：

1. 「设置 → 看板」→ 打开「上传今日进度」
2. 「服务器地址」填 `http://glk0108.site:8787`
3. 如果服务器设了口令，「共享口令」填一样的
4. 点「立即上传今天」→ 提示「已把今天的进度传上去了」
5. 回电脑刷新看板页面，应该能看到你那天的完成情况

---

## 日常运维（都在网页终端里）

```bash
# 看日志（最近 50 行，跟随刷新 Ctrl+C 退出）
journalctl -u checkin-server -n 50 -f

# 重启 / 停止 / 状态
systemctl restart checkin-server
systemctl stop checkin-server
systemctl status checkin-server --no-pager

# 备份：就一个文件（数据库），拷走即可
cp /opt/checkin/checkin.db /opt/checkin/backup-$(date +%F).db

# 升级：重新上传二进制后
systemctl restart checkin-server
```

## 出问题时先看这三样

| 现象 | 排查 |
|---|---|
| 浏览器打不开 `:8787` | 先看 `systemctl status` 是否 running；再确认**云安全组**放行了 8787（这一步最常忘） |
| 页面报「加载失败：HTTP 401」 | 服务器配了 `-key`，但看板页还没输口令（页面会弹框让你输；App 里去「共享口令」填） |
| App 提示「连不上服务器」 | 地址写成 `http://glk0108.site:8787`（**不要带 /glk**，那是面板的路径）；确认手机用的是能访问外网的网络 |

> 面板本身跑在 8887，后端跑在 8787，两者互不干扰。
> **不要把 1Panel 的 8887 口令和 checkin 的共享口令搞混**，它们没关系。

## 更新部署（已上线后换新版本 · 1Panel 无 SSH 流程）

1. 面板 → 文件 → 进 `/opt/checkin/`，上传新的 `checkin-server`，**覆盖同名文件**。
   ⚠️ 文件名必须就叫 `checkin-server`——带 `-linux-armv7` 之类的后缀会让服务
   报 “No such file or directory” 起不来（已踩过一次）。
2. 上传后看一眼权限仍是 755（1Panel 文件属性里可改）。
3. 重启服务：面板里找到 `checkin-server` 服务（systemd 单元）点重启；
   或面板自带的终端里 `systemctl restart checkin-server`。
4. 验证：浏览器打开 `http://glk0108.site:8787/api/health` 应返回 `{"ok":true}`；
   再开看板页戳一下前后日期，确认卡片显示正常。

> 数据库无需迁移：更新只换二进制，`/opt/checkin/checkin.db` 原样保留。

## 管理后台（可选，默认关闭）

地址：`http://glk0108.site:8787/admin`。**不配置管理口令 = 页面和接口一律 404（相当于不存在）**。

开启（网页终端里，把口令换成你自己的）：

```bash
sed -i 's#-db /opt/checkin/checkin.db#-db /opt/checkin/checkin.db -admin 你的管理口令#' \
  /etc/systemd/system/checkin-server.service
systemctl daemon-reload && systemctl restart checkin-server
```

改口令就把上面命令再跑一遍（旧口令 → 新口令）。管理页能干什么：

- **昵称管理**：重命名 / 合并（把某人全部数据迁到另一个名字，同一天取最新那份）；删除某昵称全部数据
- **单日数据（纠错）**：查某人某天快照、改完成数字 / 休息日、删除某天

> 改昵称的自动迁移（App 1.2.7 起）走 `/api/rename`，不需要管理口令；
> 管理页是给你手动善后用的（比如历史遗留的重复昵称）。
