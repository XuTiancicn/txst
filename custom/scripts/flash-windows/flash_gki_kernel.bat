@echo off
chcp 65001 >nul 2>nul
rem ============================================================
rem  只换内核 —— Windows 版（与 flash_gki_kernel.sh 等价）
rem  把 Google AOSP GKI 内核刷进 boot_a / boot_b 两个槽，
rem  不动 userdata，系统与数据保持原样。
rem  想刷回 Droidian 自带内核（data\boot.img）：
rem      fastboot flash boot_a data\boot.img
rem      fastboot flash boot_b data\boot.img
rem ============================================================
setlocal EnableExtensions
cd /d "%~dp0"
title marble 换 GKI 内核

echo ================================================================
echo  只换内核：boot_a / boot_b ^<- data\boot-gki.img
echo  userdata 不动，系统与数据保持原样
echo ================================================================
echo.

where fastboot >nul 2>nul
if errorlevel 1 (
  echo E: 找不到 fastboot 命令，请先把 platform-tools 加进 PATH。
  goto :fail
)
if not exist "data\boot-gki.img" (
  echo E: 缺少 data\boot-gki.img —— 这个包里没带 GKI 内核。
  goto :fail
)

set "DEVICE="
for /f "tokens=1" %%d in ('fastboot devices 2^>nul') do if not defined DEVICE set "DEVICE=%%d"
if not defined DEVICE (
  echo E: 没有检测到 fastboot 设备，请先进 fastboot 再运行。
  goto :fail
)
echo I: 设备 = %DEVICE%
echo.

echo I: 刷 boot_a ...
fastboot -s %DEVICE% flash boot_a "data\boot-gki.img"
if errorlevel 1 (
  echo E: boot_a 刷入失败
  goto :fail
)
echo I: 刷 boot_b ...
fastboot -s %DEVICE% flash boot_b "data\boot-gki.img"
if errorlevel 1 (
  echo E: boot_b 刷入失败
  goto :fail
)
echo I: 重启...
fastboot -s %DEVICE% reboot
echo I: 已刷入 GKI 内核并重启。
pause
exit /b 0

:fail
echo.
pause
exit /b 1
