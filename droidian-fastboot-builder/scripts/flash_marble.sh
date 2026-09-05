#!/usr/bin/env bash
#
# flash_marble.sh — marble (红米 Note 12 Turbo / POCO F5) 手动 fastboot 刷入
#
# flash_all.sh 是交互式/自动识别设备；此脚本为直通版：
#   - boot 双槽位都刷（无论 active slot 都能起）
#   - userdata 直接刷（sparse LVM 布局，Droidian 系统所在）
#
# 用法:
#   1. 解压 droidian-UNOFFICIAL-*-image-*.zip
#   2. 手机进 fastboot (关机, 音量下+电源)
#   3. 在本目录执行: ./flash_marble.sh
#   4. 完成后自动重启进 Droidian (默认密码 1234)
#
# 警告: 会清空整个 userdata —— 现有 /data/rootfs.img 和 Android 数据全部丢失
set -euo pipefail

[ -f data/boot.img ] || { echo "E: 未找到 data/boot.img，请在解压后的 zip 目录内运行" >&2; exit 1; }
[ -f data/userdata.img ] || { echo "E: 未找到 data/userdata.img" >&2; exit 1; }

command -v fastboot >/dev/null || { echo "E: 缺少 fastboot" >&2; exit 1; }

echo "== 等待 fastboot 设备 =="
fastboot devices

echo "== 刷 boot (A/B 双槽) =="
fastboot flash boot_a data/boot.img
fastboot flash boot_b data/boot.img

echo "== 刷 userdata (Droidian LVM rootfs) =="
fastboot flash userdata data/userdata.img

echo "== 重启 =="
fastboot reboot
echo "完成。首次启动会自动扩展 LVM，之后进入 phosh，解锁密码 1234"
