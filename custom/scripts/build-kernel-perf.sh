#!/usr/bin/env bash
# =============================================================================
# build-kernel-perf.sh
#
# Droidian marble 内核 —— 性能解锁版：
#   · 默认 cpufreq governor = performance（内核侧，开机即生效，不等用户态）
#   · 关闭 CPU 降频类 thermal governor（保留 THERMAL 框架与温度读取）
#   · 尝试关闭会钳 CPU 的 vendor 旋钮（LMH / core_ctl / mi_* 等）
#   · 叠加显示驱动（DRM_MSM built-in，复用上游 techpack）
#
# 产物：dist/boot.img（官方 5.10.238 容器 + 本内核）、dist/Image、dist/used.config
#
# 依赖：与 scripts/build_display_kernel.sh 相同的工具链（Actions ubuntu 已装）
# 用法：KERNEL_BRANCH=auto ./custom/scripts/build-kernel-perf.sh
#       （auto = 依次试 droidian-old / droidian / android12-5.10-2025-05，
#         取第一个含 arch/arm64/configs/marble_defconfig 的分支）
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # custom/
ROOT="$(cd "$HERE/.." && pwd)"                    # 仓库根
KERNEL_REPO="${KERNEL_REPO:-https://github.com/droidian-marble/linux-droidian-marble-gki.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-droidian}"
BOOTIMAGE_DEB_URL="${BOOTIMAGE_DEB_URL:-https://github.com/droidian-marble/linux-droidian-marble-gki/releases/download/latest-kernel-droidian/linux-bootimage-5.10.238-xiaomi-marble_0.0.1_arm64.deb}"
FRAGMENT="${FRAGMENT:-$HERE/kernel/perf.fragment}"

log() { echo "I: $*"; }
die() { echo "E: $*" >&2; exit 1; }

cd "$ROOT"
rm -rf kernel dist stock-238 dist-stock boot238.deb

echo "===== [1/7] clone 内核源码（自动挑分支 / defconfig） ====="
# ★ 仓库 droidian-marble/linux-droidian-marble-gki 是从 linux-droidian-marble 改名来的。
#   改名后 droidian 分支变成 GKI 树（只有 gki_defconfig + vendor/*_GKI.config），
#   老的「marble_defconfig + techpack/display」树留在 droidian-old 分支。
#   所以按候选顺序探测，取第一个真有 marble_defconfig 的分支。
CAND="$KERNEL_BRANCH"
[ "$CAND" = "auto" ] && CAND="droidian-old droidian android12-5.10-2025-05"
DEFCONFIG=""
for b in $CAND; do
    echo "--- 试分支 $b ---"
    rm -rf kernel
    if ! git clone --quiet --depth 1 --branch "$b" "$KERNEL_REPO" kernel >/dev/null 2>&1; then
        echo "  clone 失败，跳过"; continue
    fi
    for c in marble_defconfig vendor/marble_defconfig; do
        if [ -f "kernel/arch/arm64/configs/$c" ]; then DEFCONFIG="$c"; KERNEL_BRANCH="$b"; break; fi
    done
    [ -n "$DEFCONFIG" ] && break
    echo "  该分支没有 marble_defconfig"
done
[ -n "$DEFCONFIG" ] || die "候选分支都没有 marble defconfig（试过: $CAND）"
echo "★ 采用: 分支=$KERNEL_BRANCH  defconfig=$DEFCONFIG"
cd kernel
echo "kernelversion: $(make kernelversion 2>/dev/null)"
[ -d techpack/display ] || die "本分支($KERNEL_BRANCH)无 techpack/display，无法内置显示驱动"

echo "===== [2/7] 接入显示驱动符号（与上游流程一致） ====="
cat > techpack/display/Kconfig <<'KEOF'
menu "QCOM Display Drivers (techpack/display)"
config DRM_MSM
	bool "MSM DRM display driver (techpack)"
	default y
	depends on DRM
	select DRM_KMS_HELPER
	select DRM_MIPI_DSI
if DRM_MSM
config DRM_MSM_SDE
	bool "SDE display engine"
	default y
config DRM_MSM_DSI
	bool "DSI controller + panel support"
	default y
config DRM_SDE_RSC
	bool "SDE Resource State Coordinator"
	default y
config DSI_PARSER
	bool "DSI parser"
	default y
config DRM_MSM_DP
	bool "DisplayPort support"
	default n
config DRM_MSM_DP_MST
	bool "DP Multi-Stream Transport"
	default n
config DRM_MSM_DP_USBPD_LEGACY
	bool "DP USB-PD legacy HPD"
	default n
config MSM_SDE_ROTATOR
	bool "SDE hardware rotator"
	default n
config DRM_SDE_WB
	bool "SDE writeback"
	default n
config DRM_SDE_VM
	bool "SDE virtual machine support"
	default n
endif
endmenu
KEOF
grep -q 'display/Kconfig' techpack/Kconfig || \
    sed -i '/source "techpack\/datarmnet\/core\/Kconfig"/i source "techpack/display/Kconfig"' techpack/Kconfig

echo "===== [3/7] marble_defconfig + 显示符号 ====="
make ARCH=arm64 "$DEFCONFIG" >/dev/null 2>&1 || die "$DEFCONFIG 失败"
scripts/config \
    --enable DRM_MSM --enable DRM_MSM_SDE --enable DRM_MSM_DSI \
    --enable DRM_SDE_RSC --enable DSI_PARSER \
    --disable DRM_MSM_DP --disable DRM_MSM_DP_MST --disable DRM_MSM_DP_USBPD_LEGACY \
    --disable MSM_SDE_ROTATOR --disable DRM_SDE_WB --disable DRM_SDE_VM --disable HDCP_QSEECOM
make ARCH=arm64 olddefconfig >/dev/null 2>&1

echo "===== [4/7] 叠加性能解锁片段 ($(basename "$FRAGMENT")) ====="
[ -f "$FRAGMENT" ] || die "找不到片段: $FRAGMENT"
# 片段每行形如 "--enable  SYM" / "--disable SYM"，脚本注释以 # 开头
ARGS=$(grep -vE '^\s*(#|$)' "$FRAGMENT" | tr '\n' ' ')
echo "scripts/config $ARGS"
scripts/config $ARGS            # 未知符号只告警
make ARCH=arm64 olddefconfig >/dev/null 2>&1

echo "----- 解锁项最终取值（★以本段日志为准，缺失=该内核线没有此符号） -----"
for s in CPU_FREQ_DEFAULT_GOV_PERFORMANCE CPU_FREQ_GOV_PERFORMANCE CPU_FREQ_DEFAULT_GOV_SCHEDUTIL \
         THERMAL_GOV_STEP_WISE THERMAL_DEFAULT_GOV_STEP_WISE THERMAL \
         QTI_THERMAL_LMHC QTI_LMH MSM_LMH_DCVS MSM_THERMAL MSM_PERFORMANCE \
         QCOM_CPU_VENDOR_HOOKS CORE_CTL MSM_CORE_CTL SCHED_WALT MI_FREQWDG MIGT METIS \
         DRM_MSM DRM_MSM_SDE DRM_MSM_DSI; do
    v=$(grep -E "^CONFIG_${s}=" .config 2>/dev/null || echo "# ${s} is not set")
    printf '  %-40s %s\n' "$s" "${v#CONFIG_}"
done
echo "----- cpufreq governor 可用集 -----"
grep -E '^CONFIG_CPU_FREQ_(GOV|DEFAULT)' .config || true

cp .config "$ROOT/dist_used.config"

echo "===== [5/7] 编译 Image（复用 scripts/compile_kernel.sh） ====="
bash "$ROOT/scripts/compile_kernel.sh" . Image

echo "===== [6/7] 官方 5.10.238 boot.img 容器重打包 ====="
cd "$ROOT"
mkdir -p dist stock-238 dist-stock
cp kernel/arch/arm64/boot/Image dist/Image
cp dist_used.config dist/used.config
curl -sL --retry 3 -o boot238.deb "$BOOTIMAGE_DEB_URL" -w "bootimage deb HTTP %{http_code} size %{size_download}\n"
dpkg-deb -x boot238.deb dist-stock
BOOT_IMG=$(find dist-stock -name 'boot.img-*' ! -name '*recovery*' | head -1)
[ -n "$BOOT_IMG" ] || die "bootimage deb 里找不到 boot.img"
python3 scripts/unpack_boot_v4.py "$BOOT_IMG" stock-238
# 内核段必须是 raw（未压缩）—— marble ABL 不认 gzip 段（2026-09-09 实测）
cp kernel/arch/arm64/boot/Image stock-238/kernel.raw
python3 scripts/repack_boot.py stock-238/kernel.raw stock-238/header.bin \
    stock-238/ramdisk stock-238/boot_signature dist/boot.img

echo "===== [7/7] 校验 ====="
python3 - <<'PY'
import struct
d = open('dist/boot.img','rb').read()
assert d[:8] == b'ANDROID!'
hv  = struct.unpack_from('<I', d, 40)[0]
ksz = struct.unpack_from('<I', d, 8)[0]
rsz = struct.unpack_from('<I', d, 12)[0]
assert hv == 4 and ksz and rsz, (hv, ksz, rsz)
assert d[4096:4098] == b'MZ', "内核段不是 raw Image"
print(f"boot.img OK: {len(d)/1024/1024:.1f} MB  kernel={ksz/1024/1024:.1f} MB  ramdisk={rsz/1024:.0f} KB")
PY
rm -f "$ROOT/dist_used.config"
ls -lh dist/
