@echo off
chcp 936 >nul
REM ============================================================
REM  交叉编译 checkin-server 到极客云（armv7l，32 位 ARM）
REM  用法：双击运行，或命令行执行 build_arm.cmd
REM  产物：dist\checkin-server-linux-armv7（约 11MB，静态链接）
REM ============================================================
setlocal
cd /d "%~dp0"

REM 国内代理：不加这两行会去连 proxy.golang.org（Google），国内基本连不上
set GOPROXY=https://goproxy.cn,direct
set GOSUMDB=sum.golang.google.cn
REM 关掉 cgo：modernc.org/sqlite 是纯 Go 驱动，不需要交叉编译工具链
set CGO_ENABLED=0
set GOOS=linux
set GOARCH=arm
set GOARM=7

if not exist dist mkdir dist

echo [1/3] go vet ...
go vet ./...
if errorlevel 1 goto fail

echo [2/3] go test ...
go test ./...
if errorlevel 1 goto fail

echo [3/3] 交叉编译 linux/arm (armv7l) ...
go build -trimpath -ldflags "-s -w" -o dist\checkin-server-linux-armv7 .
if errorlevel 1 goto fail

echo.
echo 完成： dist\checkin-server-linux-armv7
echo 传到服务器：
echo   scp dist\checkin-server-linux-armv7 root@你的服务器:/opt/checkin/checkin-server
exit /b 0

:fail
echo.
echo 构建失败，看上面的报错。
exit /b 1
