#!/usr/bin/env bash
# =============================================================================
# build_gki_aosp.sh —— 用 Google AOSP 内核 (kernel/common) 为 marble 编 GKI 内核,
#                      并用原厂 OS2.0.5.0.VMRCNXM 的 boot 容器重打包成可刷 boot.img。
#
# 产出: dist/boot.img                 可直接 fastboot flash boot 的 GKI 映像
#       dist/gki-marble-sideload.zip  TWRP adb sideload 直刷包(自动判槽)
#       dist/Image                    未压缩 arm64 内核
#       dist/System.map / gki-*.config / gki-info.txt
#
# ═════════════════ 厂商模块到底靠什么校验（源码实证, 别想当然）═════════════════
# 装模块时内核做两道检查 (kernel/module.c @ android12-5.10.209_r00):
#
#   :3293   else if (!same_magic(modmagic, vermagic, info->index.vers)) -> -ENOEXEC
#   :1378   /* First part is kernel version, which we ignore if module has crcs. */
#           static inline int same_magic(a, b, has_crcs)
#           { if (has_crcs) { a += strcspn(a," "); b += strcspn(b," "); }
#             return strcmp(a,b) == 0; }
#
# ⇒ **模块带 CRC(GKI 模块都带)时, vermagic 里的内核版本串被内核显式跳过**,
#   真正卡住的是: ① vermagic 的标志位段(SMP/preempt/mod_unload/aarch64)
#                ② module_layout 结构体 CRC
#                ③ 每个被引用导出符号的 CRC  (check_version)
#   这三样由图版型无关的 Kconfig 决定 ⇒ 只要 defconfig 与工具链一致即可.
#
# 那为什么仍然精确复刻版本串?
#   ① 万一某个厂商 .ko 没带 __versions(无 CRC) -> 走 strcmp 全串比较, 那时
#      "版本串逐字节相同"就是硬性要求, 宁可提前满足;
#   ② dmesg / /proc/version 与原厂一致, 出问题时才能做"同一基线"取证;
#   ③ 不给自己留"版本串不同"这个变量.
# 原厂版本串(实测从原厂 boot.img 内核段 banner 直接读出, 不是猜的):
#     5.10.209-android12-9-00019-g4ea09a298bb4-ab12292661
#
# 版本串的三段构成与复刻方式:
#   5.10.209                             <- 源码树 Makefile 的 SUBLEVEL(选 tag)
#   -android12-9                         <- GKI KMI 代号(build.config.common:
#                                           BRANCH=android12-5.10 KMI_GENERATION=9)
#   -00019-g4ea09a298bb4-ab12292661      <- AOSP 构建号(源码树 git describe + ab)
# 复刻手段: 把后两段整体写进 CONFIG_LOCALVERSION, 并关掉 LOCALVERSION_AUTO,
# 同时把 LOCALVERSION 环境变量"置为空但存在"以绕开 scripts/setlocalversion
# 在非 tag 提交上追加 '+' 的分支。然后:
#   编译前 -> make kernelrelease 断言(秒级, 早失败)
#   编译后 -> 从 Image 里 grep 该串断言(万无一失)
#
# 用法:
#   bash scripts/build_gki_aosp.sh
# 可覆盖环境变量:
#   GKI_REF / KERNEL_REPO / CONTAINER / FRAGMENT / OUT
#   STOCK_UTS        原厂 release string(默认见下)
#   USE_AOSP_CLANG   1=用官方 clang r416183b(默认, 与原厂 banner 一致) / 0=用系统 clang
#   EXTRA_FRAGMENT   merge_config 风格的额外片段(可选, 逗号分隔)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/aosp-mirror/kernel_common.git}"
GKI_REF="${GKI_REF:-android12-5.10.209_r00}"
CLANG_REPO="${CLANG_REPO:-https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b.git}"
CLANG_BRANCH="${CLANG_BRANCH:-lineage-20.0}"
USE_AOSP_CLANG="${USE_AOSP_CLANG:-1}"
CONTAINER="${CONTAINER:-$ROOT/stock-os2050}"
FRAGMENT="${FRAGMENT:-$ROOT/custom/kernel/gki-aosp.fragment}"
OUT="${OUT:-$ROOT/dist}"
KERNEL_DIR="$ROOT/kernel"
TOOLCHAIN="$ROOT/toolchain"

# 原厂 HyperOS OS2.0.5.0.VMRCNXM boot.img 内核段 banner 里实测得到的 release string
STOCK_UTS="${STOCK_UTS:-5.10.209-android12-9-00019-g4ea09a298bb4-ab12292661}"

log()  { echo "I: $*"; }
warn() { echo "W: $*" >&2; }
die()  { echo "E: $*" >&2; exit 1; }

cd "$ROOT"
mkdir -p "$OUT"

# ══════════════════════════════════════════════════ [1/8] 校验原厂容器件
log "===== [1/8] 校验原厂容器件 ($CONTAINER) ====="
for f in header.bin ramdisk boot_signature parts.json; do
    [ -f "$CONTAINER/$f" ] || die "缺容器件 $CONTAINER/$f"
done
python3 - "$CONTAINER" <<'PYEOF'
import hashlib, json, os, struct, sys
d = sys.argv[1]
meta = json.load(open(os.path.join(d, "parts.json"), encoding="utf8"))
for name, key in (("ramdisk", "ramdisk_sha256"), ("boot_signature", "boot_signature_sha256")):
    got = hashlib.sha256(open(os.path.join(d, name), "rb").read()).hexdigest()
    assert got == meta[key], f"{name} sha256 与 parts.json 不符: {got} != {meta[key]}"
hdr = open(os.path.join(d, "header.bin"), "rb").read()
assert len(hdr) == 1584 and hdr[:8] == b"ANDROID!", "header.bin 不是 1584B GKI v4 header"
hv = struct.unpack_from("<I", hdr, 40)[0]
assert hv == 4, f"header_version={hv} != 4"
print(f"I:   header v{hv} OK  原厂 kernel_size={struct.unpack_from('<I', hdr, 8)[0]}"
      f"  ramdisk={len(open(os.path.join(d,'ramdisk'),'rb').read())}"
      f"  os_version=0x{struct.unpack_from('<I', hdr, 16)[0]:08x}")
print(f"I:   ramdisk/boot_signature sha256 与 parts.json 逐字节一致")
PYEOF

# ══════════════════════════════════════════════════ [2/8] 工具链
log "===== [2/8] 工具链 (USE_AOSP_CLANG=$USE_AOSP_CLANG) ====="
if [ "$USE_AOSP_CLANG" = "1" ]; then
    if [ ! -x "$TOOLCHAIN/clang-r416183b/bin/clang" ]; then
        mkdir -p "$TOOLCHAIN"
        log "clone 官方预编译 clang (r416183b = clang 12.0.5, 与原厂 banner 完全一致)"
        rm -rf "$TOOLCHAIN/clang-r416183b"
        git clone --depth 1 --branch "$CLANG_BRANCH" "$CLANG_REPO" "$TOOLCHAIN/clang-r416183b" \
            || die "官方 clang 克隆失败"
    fi
    export PATH="$TOOLCHAIN/clang-r416183b/bin:$PATH"
    [ -x "$(command -v clang)" ] || die "clang 不在 PATH"
    command -v ld.lld >/dev/null || die "官方 clang 目录里没有 ld.lld"
fi
echo "--- clang ---"; clang --version | head -2
echo "--- ld.lld ---"; ld.lld --version | head -1

# ══════════════════════════════════════════════════ [3/8] 源码
log "===== [3/8] clone Google AOSP 内核 ($GKI_REF @ $KERNEL_REPO) ====="
rm -rf "$KERNEL_DIR"
git clone --depth 1 --branch "$GKI_REF" "$KERNEL_REPO" "$KERNEL_DIR" || die "AOSP 内核克隆失败"
cd "$KERNEL_DIR"
GIT_SHA="$(git rev-parse HEAD)"
log "源码: $GKI_REF  sha=$GIT_SHA"
log "Makefile 版本行: $(grep -m3 -E '^(VERSION|PATCHLEVEL|SUBLEVEL) *=' Makefile | tr '\n' ' ')"
GIT_DESCRIBE="$(git describe --tags 2>/dev/null || echo '(shallow,无 tag 描述)')"
log "git describe: $GIT_DESCRIBE"
[ -f arch/arm64/configs/gki_defconfig ] || die "没有 arch/arm64/configs/gki_defconfig —— 这不是 GKI 树"

# ══════════════════════════════════════════════════ [4/8] 生成 .config
log "===== [4/8] gki_defconfig + 定制片段 ====="
make ARCH=arm64 LLVM=1 gki_defconfig >/dev/null
if [ -s "$FRAGMENT" ]; then
    # shellcheck disable=SC2046
    ./scripts/config --file .config $(grep -vE '^[[:space:]]*(#|$)' "$FRAGMENT")
    log "已套用片段: $FRAGMENT"
fi
if [ -n "${EXTRA_FRAGMENT:-}" ]; then
    IFS=',' read -ra _fr <<<"$EXTRA_FRAGMENT"
    ./scripts/kconfig/merge_config.sh -m .config "${_fr[@]}" >/dev/null
    log "已 merge 额外片段: $EXTRA_FRAGMENT"
fi

# ══════════════════════════════════════════════════ [5/8] 精确复刻版本串
log "===== [5/8] 复刻原厂 UTS_RELEASE ====="
KV_BASE="$(make -s ARCH=arm64 kernelversion 2>/dev/null | tail -1 || true)"
[ -n "$KV_BASE" ] || KV_BASE="$(grep -m1 '^SUBLEVEL' Makefile | awk '{print $3}' | sed 's/^/5.10./')"
log "源码基线 KERNELVERSION = $KV_BASE"
case "$STOCK_UTS" in
    "$KV_BASE"*) SUFFIX="${STOCK_UTS#$KV_BASE}" ;;
    *) die "原厂串 $STOCK_UTS 与源码基线 $KV_BASE 不匹配 —— 选错 tag 了? 请换 GKI_REF" ;;
esac
[ -n "$SUFFIX" ] || die "无法从 $STOCK_UTS 截出后缀"
log "要构造的完整 release = ${KV_BASE}${SUFFIX}"

./scripts/config --file .config --set-str LOCALVERSION "$SUFFIX"
./scripts/config --file .config --disable LOCALVERSION_AUTO
make ARCH=arm64 LLVM=1 olddefconfig >/dev/null
# LOCALVERSION 环境变量"置空但存在": scripts/setlocalversion 里
#   if test "${LOCALVERSION+set}" != "set"; then ... 追加 '+' ...
# 置空(非 unset)即可走不到那条分支。
export LOCALVERSION=""

ACTUAL="$(make -s ARCH=arm64 LLVM=1 kernelrelease 2>/dev/null | tail -1)"
log "make kernelrelease = $ACTUAL"
[ "$ACTUAL" = "$STOCK_UTS" ] || die "版本串复刻失败: 期望 $STOCK_UTS, 实得 $ACTUAL
  排查: grep -n LOCALVERSION .config; cat include/config/kernel.release; git describe --tags"

# ══════════════════════════════════════════════════ [6/8] 编译
log "===== [6/8] 编译 Image (共享核心 compile_kernel.sh) ====="
# 官方 clang 12 不需要 frame-larger-than 降级 ⇒ KCFLAGS 显式置空(保留变量以便覆盖)
KCFLAGS="${KCFLAGS-}" bash "$ROOT/scripts/compile_kernel.sh" . Image

# ══════════════════════════════════════════════════ [7/8] 装配 + 双重复核
log "===== [7/8] 装配 boot.img 并复核 ====="
IMAGE="$KERNEL_DIR/arch/arm64/boot/Image"
[ -f "$IMAGE" ] || die "没有 arch/arm64/boot/Image"
cp "$IMAGE" "$OUT/Image"

if ! grep -aqF "$STOCK_UTS" "$IMAGE"; then
    die "Image 里找不到版本串 $STOCK_UTS —— 编译期被覆盖了, 产物不可用"
fi
log "Image banner 断言通过: 内含 $STOCK_UTS"

python3 "$ROOT/scripts/repack_boot.py" \
    "$IMAGE" \
    "$CONTAINER/header.bin" \
    "$CONTAINER/ramdisk" \
    "$CONTAINER/boot_signature" \
    "$OUT/boot.img"

python3 - "$OUT/boot.img" "$CONTAINER" "$IMAGE" "$STOCK_UTS" <<'PYEOF'
import json, os, struct, sys
img, cont, image_path, uts = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = open(img, "rb").read()
meta = json.load(open(os.path.join(cont, "parts.json"), encoding="utf8"))
assert d[:8] == b"ANDROID!", "BOOT_MAGIC 错"
g = lambda o: struct.unpack_from("<I", d, o)[0]
ksz, rsz, hv, sigsz = g(8), g(12), g(40), g(1580)
ist = os.path.getsize(image_path)
assert hv == 4, f"header_version={hv}"
assert ksz == ist, f"kernel_size {ksz} != Image {ist}"
assert rsz == meta["ramdisk_size"], f"ramdisk_size 变了: {rsz} != {meta['ramdisk_size']}"
assert sigsz == 4096, f"boot_signature_size={sigsz}"
assert d[4096:4096+2] == b"MZ", "内核段不是 raw arm64 PE/COFF Image (原厂布局要求 raw)"
assert uts.encode() in d[4096:4096+ksz], "boot.img 内核段里找不到版本串"
print(f"I:   boot.img {len(d)} bytes  kernel={ksz/1024/1024:.2f}MB(raw)  "
      f"ramdisk={rsz}  sig={sigsz}  os_version=0x{g(16):08x}")
print(f"I:   版本串复核通过: {uts}")
PYEOF

# ══════════════════════════════════════════════════ [8/8] 周边产物
log "===== [8/8] OTA 包 + 配置 + 说明 ====="
cp "$KERNEL_DIR/.config" "$OUT/gki-aosp-used.config"
[ -f "$KERNEL_DIR/System.map" ] && cp "$KERNEL_DIR/System.map" "$OUT/System.map" || true
python3 "$ROOT/scripts/make_sideload_zip.py" \
    "$OUT/boot.img" "$OUT/gki-marble-sideload.zip" "$STOCK_UTS"

{
  echo "# marble AOSP GKI 内核构建信息"
  echo "设备            : marble (Redmi Note 12 Turbo / POCO F5, SM7475)"
  echo "内核源码        : $KERNEL_REPO @ $GKI_REF (Google AOSP kernel/common)"
  echo "源码 sha        : $GIT_SHA"
  echo "源码 git describe: $GIT_DESCRIBE"
  echo "UTS_RELEASE     : $STOCK_UTS   (与 $STOCK_UTS 完全一致 = 厂商模块可加载)"
  echo "boot 容器来源   : $CONTAINER  ($(python3 -c "import json;print(json.load(open('$CONTAINER/parts.json'))['source'])" 2>/dev/null || echo '?'))"
  echo "容器 ramdisk    : $(python3 -c "import json;print(json.load(open('$CONTAINER/parts.json'))['ramdisk_sha256'])" 2>/dev/null || echo '?')"
  echo "工具链          : $(clang --version | head -1)"
  echo "配置片段        : $FRAGMENT"
  echo "编译时间(UTC)   : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "## 生效的关键配置"
  grep -E '^CONFIG_(LOCALVERSION|CFI_CLANG|LTO_|SHADOW_CALL_STACK|CPU_FREQ_DEFAULT_GOV|MODVERSIONS|MODULE_SIG|WERROR)' "$OUT/gki-aosp-used.config" || true
} > "$OUT/gki-info.txt"
cat "$OUT/gki-info.txt"

echo
log "产物清单:"
ls -lh "$OUT/"
echo
log "OK: 全部完成"
