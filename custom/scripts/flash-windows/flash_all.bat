@echo off
chcp 65001 >nul 2>nul
rem ============================================================
rem  marble Droidian 整刷脚本 —— Windows 版
rem  与同目录的 flash_all.sh 逻辑等价，二者任选其一。
rem  * 会清空 userdata 分区（手机里全部数据）
rem  用法：整个包解压后，双击本文件，或在 cmd 里执行 flash_all.bat
rem ============================================================
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title marble Droidian 整刷

echo ================================================================
echo  marble Droidian 整刷（Windows）
echo  警告：会清空 userdata 分区（手机里全部数据）
echo ================================================================
echo.

rem ---------- 1. 环境自检 ----------
where fastboot >nul 2>nul
if errorlevel 1 (
  echo E: 找不到 fastboot 命令。
  echo    请安装 Android platform-tools，并把它的目录加进 PATH（例如 C:/platform-tools）。
  echo    自检：新开一个 cmd 执行  fastboot --version  应该能打印版本号。
  goto :fail
)

if not exist "data\userdata.img" (
  echo E: 找不到 data\userdata.img
  echo    请确认本 .bat 与 data 目录在同一层（即解压出来的根目录）后再运行。
  goto :fail
)

rem ---------- 2. 读设备配置（等价于 shell 的 source data/device-configuration.conf） ----------
rem 先给保守缺省值，再用配置文件覆盖；未出现的键保持缺省。
set "DEVICE_IS_AB=no"
set "DEVICE_IS_LEGACY=no"
set "DEVICE_HAS_CAPITAL_NAME=no"
set "DEVICE_HAS_DTBO_PARTITION=no"
set "DEVICE_HAS_VBMETA_PARTITION=no"
set "DEVICE_HAS_VENDORBOOT_PARTITION=no"
set "USERDATA_FLASHING_METHOD="
if exist "data\device-configuration.conf" (
  for /f "usebackq eol=# tokens=1,* delims==" %%a in ("data\device-configuration.conf") do set "%%a=%%b"
)
echo I: A/B=%DEVICE_IS_AB%  Legacy=%DEVICE_IS_LEGACY%  大写分区名=%DEVICE_HAS_CAPITAL_NAME%
echo I: dtbo=%DEVICE_HAS_DTBO_PARTITION%  vbmeta=%DEVICE_HAS_VBMETA_PARTITION%  vendor_boot=%DEVICE_HAS_VENDORBOOT_PARTITION%

if /i "%USERDATA_FLASHING_METHOD%"=="telnet" (
  echo E: 本包的 userdata.img 需要用 telnet 方式刷入，Windows 脚本不支持这种机型。
  echo    请改用 Linux/macOS 下的 ./flash_all.sh。
  goto :fail
)

rem ---------- 3. 找设备 ----------
set "DEVICE="
for /f "tokens=1" %%d in ('fastboot devices 2^>nul') do if not defined DEVICE set "DEVICE=%%d"
if not defined DEVICE (
  echo E: 没有检测到 fastboot 设备。
  echo    1^) 手机关机，按住 音量减 + 电源 进入 fastboot（屏幕显示 FASTBOOT）
  echo    2^) 数据线连电脑，Windows 装好 USB 驱动
  echo    3^) 另开 cmd 执行  fastboot devices  应能列出序列号
  goto :fail
)
echo I: 设备 = %DEVICE%
echo.

rem ---------- 4. 二次确认 ----------
set "ANS="
set /p "ANS=确认刷入 %DEVICE% 吗？会清空 userdata。（输入 y 继续，其它键取消）: "
if /i not "%ANS%"=="y" (
  echo 已取消，未做任何改动。
  pause
  exit /b 0
)
echo.

rem ---------- 5. 分区命名模式（对齐 flash_all.sh 的四个分支） ----------
set "MODE=ALOWER"
if /i "%DEVICE_IS_AB%"=="yes"   set "MODE=ALOWER"
if /i not "%DEVICE_IS_AB%"=="yes" set "MODE=SLOWER"
if /i "%DEVICE_IS_AB%"=="yes"   if /i "%DEVICE_HAS_CAPITAL_NAME%"=="yes" set "MODE=ACAPS"
if /i not "%DEVICE_IS_AB%"=="yes" if /i "%DEVICE_HAS_CAPITAL_NAME%"=="yes" set "MODE=SCAPS"
echo I: 分区命名模式 = %MODE%  ^(A=双侧槽  S=单槽  CAPS=大写分区名^)
echo.

set "RC=0"

if /i "%MODE%"=="ACAPS" (
  call :fp BOOT_a data\boot.img
  call :fp BOOT_b data\boot.img
  if /i "!DEVICE_HAS_DTBO_PARTITION!"=="yes"       ( call :fp DTBO_a data\dtbo.img & call :fp DTBO_b data\dtbo.img )
  if /i "!DEVICE_HAS_VBMETA_PARTITION!"=="yes"     ( call :fp VBMETA_a data\vbmeta.img & call :fp VBMETA_b data\vbmeta.img )
  if /i "!DEVICE_HAS_VENDORBOOT_PARTITION!"=="yes" ( call :fp VENDOR_BOOT_a data\vendor_boot.img & call :fp VENDOR_BOOT_b data\vendor_boot.img )
  call :fp USERDATA data\userdata.img
)

if /i "%MODE%"=="ALOWER" (
  call :fp boot_a data\boot.img
  call :fp boot_b data\boot.img
  if /i "!DEVICE_HAS_DTBO_PARTITION!"=="yes"       ( call :fp dtbo_a data\dtbo.img & call :fp dtbo_b data\dtbo.img )
  if /i "!DEVICE_HAS_VBMETA_PARTITION!"=="yes"     ( call :fp vbmeta_a data\vbmeta.img & call :fp vbmeta_b data\vbmeta.img )
  if /i "!DEVICE_HAS_VENDORBOOT_PARTITION!"=="yes" ( call :fp vendor_boot_a data\vendor_boot.img & call :fp vendor_boot_b data\vendor_boot.img )
  call :fp userdata data\userdata.img
)

if /i "%MODE%"=="SCAPS" (
  call :fp BOOT data\boot.img
  if /i "!DEVICE_HAS_DTBO_PARTITION!"=="yes"       call :fp DTBO data\dtbo.img
  if /i "!DEVICE_HAS_VBMETA_PARTITION!"=="yes"     call :fp VBMETA data\vbmeta.img
  if /i "!DEVICE_HAS_VENDORBOOT_PARTITION!"=="yes" call :fp VENDOR_BOOT data\vendor_boot.img
  call :fp USERDATA data\userdata.img
)

if /i "%MODE%"=="SLOWER" (
  call :fp boot data\boot.img
  if /i "!DEVICE_HAS_DTBO_PARTITION!"=="yes"       call :fp dtbo data\dtbo.img
  if /i "!DEVICE_HAS_VBMETA_PARTITION!"=="yes"     call :fp vbmeta data\vbmeta.img
  if /i "!DEVICE_HAS_VENDORBOOT_PARTITION!"=="yes" call :fp vendor_boot data\vendor_boot.img
  call :fp userdata data\userdata.img
)

if not "%RC%"=="0" (
  echo.
  echo E: 有分区刷入失败，已中止，未重启。请把上面的日志发给维护者。
  goto :fail
)

echo.
echo I: 刷写完成，正在重启...
fastboot -s %DEVICE% reboot
echo I: 完成。首次开机较慢（会自动把 LVM 扩到 userdata 分区满），默认解锁密码 1234。
pause
exit /b 0

rem ---------- 子过程：刷一个分区（镜像不存在就跳过，等同 flash_if_exists） ----------
:fp
if not exist "%~2" (
  echo W: 跳过 %~1 —— 包里没有 %~2
  exit /b 0
)
echo I: 刷 %~1  ^<-  %~2
fastboot -s %DEVICE% flash %~1 "%~2"
if errorlevel 1 (
  echo E: %~1 刷入失败
  set "RC=1"
)
exit /b 0

:fail
echo.
pause
exit /b 1
