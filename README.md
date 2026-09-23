# 每日打卡 · checkin

三人自用的小打卡 App：**数据全部在本地**，可选接入 DeepSeek 做周期总结；每天自动把打卡进度同步到共享看板，网页上谁打了谁没打一目了然。

**任务模型**：一条任务只有三个属性——归属日期、每天重复、截止日期。单次 / 重复 / 周期三种形态由它们自动派生，没有容易打架的"任务类型"字段。

## 功能

- **今日**：按形态分组展示，右下角一键新建；点卡片进详情（编辑 / 归档 / 删除）
- **睡前总结**：3 个引导问题（收获 / 卡点 / 明天最重要），一天一条，可补写
- **总览**：月历热力图、连续达标、休息日（不算断签、不提醒），点日期回看当天明细
- **共享看板**：每天自动上传快照；周期任务跨天带「延续」显示；断更会标「未同步」
- **AI 周期总结**（可选）：周 / 半月 / 月严格按日历层级，手动生成，不后台打扰
- **提醒**：系统闹钟唤醒（`AlarmManager`），App 不用常驻、不加任何新权限
- **导出**：JSON 全量备份（含 AI 总结）+ CSV 汇总

## 安装（手机）

1. 到 [Releases](../../releases) 下载 `checkin_app-v*-universal.apk` 安装
2. 首次打开填昵称 —— 就是你在看板上的名字
3. 设置 → 看板地址，填你的服务器地址，之后每天打卡自动上传

> ⚠️ 覆盖安装升级不会丢数据；**别卸载重装**（本地数据会清空）。

## 服务端（看板用，可选）

Go 单文件二进制 + SQLite，armv7 小机器（树莓派 / 1Panel）也能跑：

```bash
./checkin-server -addr :8787 -db checkin.db
```

部署、更新与 `/admin` 管理后台（可选口令）见 `server/DEPLOY-1PANEL.md`。

## 构建（开发者）

需要 Flutter stable + JDK 17：

```bash
flutter pub get
flutter analyze && flutter test
flutter build apk --release --no-pub --target-platform android-arm64,android-arm
```

> 构建时带 `--no-pub`：国内镜像只镜像 pub 元数据，包归档会重定向回 pub.dev 容易卡住；依赖装好一次即可。

## 赞赏

如果这个项目对你有帮助，欢迎请作者喝杯奶茶：

<img src="docs/收款码.jpg" width="260" alt="微信收款码">
