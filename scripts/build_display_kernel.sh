#!/usr/bin/env bash
# =============================================================================
# build_display_kernel.sh
# 编译带显示驱动的 Droidian marble 内核 (5.10.238 + techpack/display built-in)
#
# 背景(已源码级核实):
#   - 官方所有 Droidian marble 内核线都不编显示驱动: gki/非gki/Melt 的 linux-image
#     均无 .ko, config 无 CONFIG_DRM_MSM (仅 CONFIG_DRM=y)
#   - 但 droidian-marble/linux-droidian-marble @ droidian 分支自带完整
#     techpack/display (sde/dsi/dp/mi_disp), 且顶层 Makefile 已 drivers-y 含 techpack,
#     techpack/Kbuild: obj-y += 全部子目录 (含 display), display/Kbuild: obj-y += msm/
#     msm/Kbuild: obj-$(CONFIG_DRM_MSM) += msm_drm.o
#   - 因此只需: 把 display 符号接入内核 Kconfig + 开 CONFIG_DRM_MSM 系列 -> built-in
#   - marble = SM7475 (waipio 家族): 官方 config CONFIG_ARCH_WAIPIO=y,
#     msm/Kbuild 会自动 include config/gki_waipiodisp.conf
#   - 官方 config: CONFIG_LOCALVERSION="-Melt", CONFIG_MODVERSIONS=y
#
# 产物:
#   dist/boot.img     = 官方 5.10.238 boot.img 容器(原 ramdisk) + 新内核段
#   dist/Image        = 未压缩内核 (显示驱动 built-in)
#
# 依赖工具 (Actions ubuntu 已装): git curl clang llvm lz4 cpio bc flex bison libssl-dev
# 可选: KERNEL_REPO / KERNEL_BRANCH / BOOTIMAGE_DEB_URL 环境变量覆盖
# =============================================================================
set -euo pipefail

WORK="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/droidian-marble/linux-droidian-marble.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-droidian}"
# 官方 5.10.238 bootimage deb (容器: 原 header+ramdisk 与 238 内核配套)
BOOTIMAGE_DEB_URL="${BOOTIMAGE_DEB_URL:-https://github.com/droidian-marble/linux-droidian-marble/releases/download/latest-kernel-droidian/linux-bootimage-5.10.238-xiaomi-marble_0.0.1_arm64.deb}"

echo "===== [1/7] swap 兜底 (runner 自带 swap 占用 /swapfile, 换路径) ====="
free -h | head -2 || true
if ! swapon --show | grep -q swap8g; then
    if [ ! -f /mnt/swap8g ]; then
        dd if=/dev/zero of=/mnt/swap8g bs=1M count=8192 status=none || true
    fi
    chmod 600 /mnt/swap8g 2>/dev/null || true
    mkswap /mnt/swap8g 2>/dev/null && swapon /mnt/swap8g 2>/dev/null || echo "WARN: swap8g 未生效, 继续"
fi
free -h | head -2 || true

echo "===== [2/7] clone 内核源码 ($KERNEL_BRANCH) ====="
rm -rf kernel
git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" kernel 2>&1 | tail -2
cd kernel
KVER=$(make kernelversion 2>/dev/null || echo "5.10.238")
echo "内核版本: $KVER"
grep -c "CONFIG_DRM" arch/arm64/configs/marble_defconfig || true

echo "===== [3/7] Kconfig 补丁: 接入 display 符号 ====="
# 3a. 新建 techpack/display/Kconfig 定义显示符号 (bool, 默认 y)
cat > techpack/display/Kconfig <<'KEOF'
menu "QCOM Display Drivers (techpack/display)"

config DRM_MSM
	bool "MSM DRM display driver (techpack)"
	default y
	depends on DRM
	select DRM_KMS_HELPER
	select DRM_MIPI_DSI
	help
	  Qualcomm MSM display driver from techpack/display (SDE/DSI/mi_disp).
	  Built-in so the framebuffer/DRM comes up without any modules.

if DRM_MSM

config DRM_MSM_SDE
	bool "SDE display engine"
	default y
	help
	  Snapdragon Display Engine core (crtc/encoder/plane/hw).

config DRM_MSM_DSI
	bool "DSI controller + panel support"
	default y
	help
	  DSI host controller and DSI panel framework.

config DRM_SDE_RSC
	bool "SDE Resource State Coordinator"
	default y

config DSI_PARSER
	bool "DSI parser"
	default y

config DRM_MSM_DP
	bool "DisplayPort support"
	default n
	help
	  Not needed for internal panel; disable to cut dependencies (hdcp etc).

config DRM_MSM_DP_MST
	bool "DP Multi-Stream Transport"
	default n

config DRM_MSM_DP_USBPD_LEGACY
	bool "DP USB-PD legacy HPD"
	default n

config MSM_SDE_ROTATOR
	bool "SDE hardware rotator"
	default n
	help
	  Rotator is only needed for hardware rotation offload; disable.

config DRM_SDE_WB
	bool "SDE writeback"
	default n

config DRM_SDE_VM
	bool "SDE virtual machine support"
	default n

endif # DRM_MSM

endmenu
KEOF

# 3b. techpack/Kconfig 挂上 display 的 Kconfig
if ! grep -q "display/Kconfig" techpack/Kconfig; then
    sed -i '/source "techpack\/datarmnet\/core\/Kconfig"/i source "techpack/display/Kconfig"' techpack/Kconfig
fi
echo "--- techpack/Kconfig 补丁后 ---"
grep -n "source" techpack/Kconfig

echo "===== [4/7] 生成 .config + 开启显示符号 ====="
make ARCH=arm64 marble_defconfig > /dev/null 2>&1 || { echo "marble_defconfig 失败"; exit 1; }

# 用 scripts/config 打开显示符号 (符号经 Kconfig 补丁定义, olddefconfig 不会被清)
scripts/config \
    --enable DRM_MSM \
    --enable DRM_MSM_SDE \
    --enable DRM_MSM_DSI \
    --enable DRM_SDE_RSC \
    --enable DSI_PARSER \
    --disable DRM_MSM_DP \
    --disable DRM_MSM_DP_MST \
    --disable DRM_MSM_DP_USBPD_LEGACY \
    --disable MSM_SDE_ROTATOR \
    --disable DRM_SDE_WB \
    --disable DRM_SDE_VM \
    --disable HDCP_QSEECOM

make ARCH=arm64 olddefconfig > /dev/null 2>&1

echo "--- 显示相关最终状态 ---"
grep -E "^CONFIG_(DRM_MSM|DRM_MSM_SDE|DRM_MSM_DSI|DRM_SDE_RSC|DSI_PARSER|DRM_MSM_DP|MSM_SDE_ROTATOR|DRM_SDE_WB|HDCP_QSEECOM|ARCH_WAIPIO|DRM=|QCOM_KGSL|LOCALVERSION)" .config
echo "--- 未定义符号核对 (应为空) ---"
for s in CONFIG_DRM_MSM CONFIG_DRM_MSM_SDE CONFIG_DRM_MSM_DSI; do
    grep -q "^${s}=y" .config && echo "OK  ${s}=y" || echo "MISS ${s} 未生效!"
done

echo "===== [5/7] 编译内核 Image (显示 built-in, 约 30-60 分钟) ====="
# 日志落盘; 失败时先抓 error 上下文再 tail (make -j 并行输出会把真实错误顶出窗口)
# KCFLAGS=-Wno-frame-larger-than: Ubuntu clang 编译 5.10 内核 io_issue_sqe 栈帧 2560B>2048B 报 -Werror (官方 Android prebuilt clang 帧布局不同不触发)
make ARCH=arm64 LLVM=1 KCFLAGS=-Wno-frame-larger-than -j"$(nproc)" Image > build.log 2>&1 \
    || { echo "===== 编译失败: error 上下文 ====="; \
         grep -n -E "error:|Error [0-9]+|Killed|fatal|undefined reference|No space left" build.log | head -40; \
         echo "===== 编译失败: 末尾 50 行 ====="; tail -50 build.log; exit 1; }
tail -5 build.log
ls -lh arch/arm64/boot/Image
mkdir -p dist
cp arch/arm64/boot/Image dist/Image

echo "===== [6/7] 下载官方 5.10.238 boot.img 容器并重打包 ====="
cd "$WORK"
rm -rf stock-238 dist-stock
mkdir -p stock-238
curl -sL --retry 3 -o boot238.deb "$BOOTIMAGE_DEB_URL" -w "bootimage deb HTTP %{http_code} size %{size_download}\n"
# 提取 deb 内 boot.img
dpkg-deb -x boot238.deb dist-stock 2>/dev/null || python3 - <<'PYEOF'
import io, tarfile, glob, os, sys
deb = glob.glob("boot238.deb")[0]
data = open(deb,'rb').read()
pos = 8
os.makedirs("dist-stock", exist_ok=True)
while pos < len(data):
    hdr = data[pos:pos+60]
    name = hdr[0:16].decode().strip()
    size = int(hdr[48:58].decode().strip())
    body = data[pos+60:pos+60+size]
    if name.startswith('data'):
        tf = tarfile.open(fileobj=io.BytesIO(body))
        for t in tf.getmembers():
            if t.isfile() and 'boot.img' in t.name and 'recovery' not in t.name:
                p = os.path.join("dist-stock", t.name.lstrip('./'))
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p,'wb') as f:
                    f.write(tf.extractfile(t).read())
                print("提取:", t.name, os.path.getsize(p))
        tf.close()
    pos += 60 + size + (size % 2)
PYEOF
BOOT_IMG=$(find dist-stock -name "boot.img-*" | head -1)
[ -z "$BOOT_IMG" ] && { echo "boot.img 未找到"; exit 1; }
ls -lh "$BOOT_IMG"

python3 scripts/unpack_boot_v4.py "$BOOT_IMG" stock-238
python3 scripts/repack_boot.py \
    kernel/arch/arm64/boot/Image \
    stock-238/header.bin \
    stock-238/ramdisk \
    stock-238/boot_signature \
    dist/boot.img

echo "===== [7/7] 校验最终 boot.img ====="
python3 - <<'PYEOF'
import struct
d = open('dist/boot.img','rb').read()
assert d[:8] == b'ANDROID!'
hv = struct.unpack_from('<I', d, 40)[0]
ksz = struct.unpack_from('<I', d, 8)[0]
rsz = struct.unpack_from('<I', d, 12)[0]
sigsz = struct.unpack_from('<I', d, 1580)[0]
print(f"总大小: {len(d)} bytes")
print(f"header_version={hv} kernel_size={ksz} ({ksz/1024/1024:.1f} MB) ramdisk_size={rsz} signature_size={sigsz}")
assert hv == 4 and ksz > 0 and rsz > 0
# 内核段应为未压缩 Image (MZ 头是 arm64 Image PE 兼容占位, 真魔数在 0x38)
k = d[4096:4096+ksz]
assert k[:2] == b'MZ', "内核段不是 Image"
print("Image MZ 头 OK, boot.img 校验通过")
PYEOF

echo ""
echo "✅ 完成! 产物:"
ls -lh dist/
echo ""
echo "说明: dist/boot.img 已含显示驱动(内置), 可 fastboot flash boot_a/boot_b 或打包进整刷 zip"
