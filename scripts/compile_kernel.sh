#!/usr/bin/env bash
# =============================================================================
# compile_kernel.sh — 共用内核编译核心 (两个内核任务单点共用)
#
# 负责: swap 兜底 -> make Image(KCFLAGS 修复) -> 失败诊断 -> 产物确认
# 用法: compile_kernel.sh <内核目录> [make目标, 默认 Image]
#
# 使用方 (改编译参数只改这里, 防止各任务独立维护漏修复):
#   - .github/workflows/build-kernel.yml  ->  LineageOS 23.2 GKI 内核
#   - scripts/build_display_kernel.sh     ->  Droidian 5.10.238 + DRM_MSM
#
# ⚠ 历史坑 (勿删, 每条都真实炸过 Actions):
#   1. OOM: GitHub runner 自带 3G swap 占 /swapfile, fallocate 覆盖报
#      "Text file busy" -> && 链断 mkswap/swapon 全没执行 -> 16核并行 OOM killer
#      杀编译. 修复: 换路径 /mnt/swap8g + dd 兜底 (实测 Swap: 10Gi)
#   2. frame-larger-than: Ubuntu clang 18 编 5.10 内核 io_uring.c io_issue_sqe
#      栈帧 2560B > CONFIG_FRAME_WARN=2048 且 -Werror 直接报错. 官方 Android
#      prebuilt clang 帧布局不同不触发. 修复: KCFLAGS=-Wno-frame-larger-than 降级
#   3. 错误被吞: make -j 并行输出全进 build.log, 真实 error 行被其他 CC 进度
#      顶出 tail 窗口, 日志看起来"无错误却失败". 修复: 先 grep error 上下文再 tail
# =============================================================================
set -euo pipefail

KDIR="${1:?用法: compile_kernel.sh <内核目录> [make目标, 默认 Image]}"
TARGET="${2:-Image}"

cd "$KDIR" || { echo "无法进入内核目录: $KDIR"; exit 1; }
echo "===== [编译] swap 兜底 ($PWD) ====="
free -h | head -2 || true
# sudo 自适应: Actions runner 有 passwordless sudo; 本地 root/无 sudo 也可跑
SUDO=""
if command -v sudo >/dev/null 2>&1 && ! sudo -n true 2>/dev/null; then SUDO=""; fi
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then SUDO="sudo"; fi
if ! swapon --show 2>/dev/null | grep -q swap8g; then
    if [ ! -f /mnt/swap8g ]; then
        $SUDO dd if=/dev/zero of=/mnt/swap8g bs=1M count=8192 status=none 2>/dev/null || true
    fi
    $SUDO chmod 600 /mnt/swap8g 2>/dev/null || true
    $SUDO mkswap /mnt/swap8g 2>/dev/null && $SUDO swapon /mnt/swap8g 2>/dev/null \
        || echo "WARN: swap8g 未生效, 继续尝试编译"
fi
free -h | head -2 || true

echo "===== [编译] make $TARGET (LLVM=1 KCFLAGS=-Wno-frame-larger-than, -j$(nproc)) ====="
# 日志落盘; 失败时先抓 error 上下文再 tail (make -j 并行输出会把真实错误顶出窗口)
make ARCH=arm64 LLVM=1 KCFLAGS=-Wno-frame-larger-than -j"$(nproc)" "$TARGET" > build.log 2>&1 \
    || { echo "===== 编译失败: error 上下文 ====="; \
         grep -n -E "error:|Error [0-9]+|Killed|fatal|undefined reference|No space left" build.log | head -40; \
         echo "===== 编译失败: 末尾 50 行 ====="; tail -50 build.log; exit 1; }
tail -8 build.log
echo "===== 产物 ====="
ls -lh "arch/arm64/boot/$TARGET"
