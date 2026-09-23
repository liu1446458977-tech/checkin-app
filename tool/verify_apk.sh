#!/usr/bin/env bash
# release APK 交付前的六项验收（Windows / git-bash）
# 用法: bash tool/verify_apk.sh [apk路径]
set -u
APK="${1:-build/app/outputs/flutter-apk/app-release.apk}"
BT="/c/Users/torch/AppData/Local/Android/Sdk/build-tools/36.0.0"

if [ ! -f "$APK" ]; then echo "❌ 找不到 APK: $APK"; exit 1; fi

echo "==================== 0) 出包检查：默认服务器地址 ===================="
SRC="$(dirname "$0")/../lib/services/board_client.dart"
if [ -f "$SRC" ]; then
  if grep -q "kDefaultBoardUrl = ''" "$SRC"; then
    echo "⚠️⚠️⚠️ 默认服务器地址为空！这版包发给老用户会让他们整体掉线"
    echo "    （老用户手机里没存过地址、靠内置默认值，设置页也没有地址入口）"
    echo "    发版前：把 lib/services/board_client.dart 里 kDefaultBoardUrl 填回服务器地址"
    echo "    （若确认就是要发空白版：删掉本条检查再跑）"
    exit 1
  fi
  grep -n "kDefaultBoardUrl =" "$SRC" | head -2
  echo "✓ 默认服务器地址已填（核对上面一行）"
else
  echo "（未找到 $SRC，跳过此检查）"
fi
echo ""

echo "==================== 1) 文件 ===================="
ls -lh "$APK" | awk '{print "路径: '"$APK"'\n体积: "$5}'

echo "==================== 2) SHA256 ===================="
sha256sum "$APK"

echo "==================== 3) 包信息 ===================="
"$BT/aapt2.exe" dump badging "$APK" 2>/dev/null | grep -E "^package:|^application-label:|^sdkVersion|^targetSdkVersion|native-code" | head -8

echo "==================== 4) 权限 ===================="
"$BT/aapt2.exe" dump badging "$APK" 2>/dev/null | grep "^uses-permission"

echo "==================== 5) 提醒相关组件是否进包 ===================="
"$BT/aapt2.exe" dump xmltree --file AndroidManifest.xml "$APK" 2>/dev/null \
  | grep -oE "DailyReminderReceiver|BootReceiver|BOOT_COMPLETED|checkin_app/reminders|checkin_app/secure|checkin_app/export" \
  | sort | uniq -c

echo "==================== 6) Kotlin/Java 代码是否进包 ===================="
python - "$APK" <<'PY'
import sys, zipfile, re
apk = sys.argv[1]
z = zipfile.ZipFile(apk)
names = z.namelist()
dexs = [n for n in names if re.fullmatch(r"classes\d*\.dex", n)]
blob = b"".join(z.read(d) for d in dexs)
# 注意：Kotlin 类名会被 R8 重命名，所以拿「行为标志」而不是类名来查
# （setAndAllowWhileIdle = 原生闹钟 API 调用，改名也留着）
for needle in [b"setAndAllowWhileIdle", b"DailyReminderReceiver", b"BootReceiver", b"checkin_reminder"]:
    print(f"  {'✓' if needle in blob else '✗'} dex 中含 {needle.decode()}")
abis = sorted({n.split('/')[1] for n in names if n.startswith('lib/')})
print("  ABIs:", abis, "（应为 arm64-v8a + armeabi-v7a，不含 x86_64）")
print("  含 libflutter.so:", any(n.endswith('libflutter.so') for n in names))
print("  含 libapp.so:", any(n.endswith('libapp.so') for n in names))
print("  dex 数:", len(dexs))
PY
echo "================================================="
