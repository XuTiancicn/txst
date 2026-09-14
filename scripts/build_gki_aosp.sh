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
# 版本串的三段构成与复刻方式(全部有源码依据, 逐行可查):
#   5.10.209                             <- Makefile VERSION/PATCHLEVEL/SUBLEVEL(选 tag)
#   -android12-9                         <- GKI KMI 代号(build.config.common:
#                                           BRANCH=android12-5.10 KMI_GENERATION=9)
#   -00019-g4ea09a298bb4-ab12292661      <- AOSP 构建号(git describe + ab)
#
#   [基线]      由 tag 决定, 不用管
#   [KMI+describe] -> CONFIG_LOCALVERSION
#       依据 scripts/setlocalversion:200  res="${res}${CONFIG_LOCALVERSION}${LOCALVERSION}"
#   [-ab<号>]   -> 环境变量 BUILD_NUMBER
#       依据 Makefile:1390  ifneq (,$(BUILD_NUMBER)) UTS_RELEASE=$(KERNELRELEASE)-ab$(BUILD_NUMBER)
#       (故 CONFIG_LOCALVERSION 里不能自带 -ab 段, 否则重复)
#   [抑制追加 '+'] -> 把 LOCALVERSION 置为"空但已定义"
#       依据 setlocalversion:211  if test "${LOCALVERSION+set}" != "set"; then res="$res${scm:++}"; fi
#   [抑制重复 KMI] -> 不向 make 传 BRANCH/KMI_GENERATION
#       依据 Makefile:2029  setlocalversion <srctree> $(BRANCH) $(KMI_GENERATION)
#       (传了会再加一次 -android12-9, 所以此处刻意不传)
#
# ★踩过的坑(run#23 就死在这, 日志 Release tag debug-gki-23):
#   `make kernelrelease` 在 no-sync-config-targets 里(Makefile:289) ⇒ 走 config-build
#   分支(见 Makefile:633 `else #!config-build` 之后才是 auto.conf 那套), 既不生成也不
#   包含 include/config/auto.conf; 而 setlocalversion:186 一旦发现 auto.conf 不存在
#   就直接 `exit 1`, 且只往 stderr 喊("kernelrelease not valid - run 'make prepare'"),
#   我们的 $( ) 把 stderr 丢了 ⇒ 捕获为空 ⇒ 版本串退化成裸基线 5.10.209。
#   修法: 断言前显式 `make syncconfig`(= kconfig --syncconfig, 静默) 生成 auto.conf。
#
#   编译前 -> make kernelrelease 断言 + auto.conf 内容打印(秒级, 早失败且自带诊断)
#   编译后 -> 从 Image 里 grep 该串断言(万无一失)
#   兜底   -> 万一自然路径仍失败, 改用 make 命令行变量 KERNELRELEASE=<原厂串> 钉死
#             (Makefile:367 是 `KERNELRELEASE = $(shell cat ...)`, 命令行变量优先级更高),
#             最终验收仍是"Image 里必须能 grep 到原厂串"
#
# 用法:
#   bash scripts/build_gki_aosp.sh
# 可覆盖环境变量:
#   GKI_REF / KERNEL_REPO / CONTAINER / FRAGMENT / OUT
#   STOCK_UTS        原厂 release string(默认见下)
#   USE_AOSP_CLANG   1=用官方 clang r416183b(默认, 与原厂 banner 一致) / 0=用系统 clang
#   CROSS_COMPILE    默认 aarch64-linux-gnu-  ★必须给★: 纯 AOSP 5.10 树只有
#                    CROSS_COMPILE 非空时才会给 clang 传 --target(Makefile:590),
#                    否则 clang 按宿主 x86_64 编, asm-offsets.s 立刻报
#                    "register 'sp' unsuitable for global register variables"
#   LLVM_IAS         默认 1 = 用 clang 集成汇编器(不依赖 GNU as 版本)
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

# ---- 目标三元组: ★纯 AOSP 5.10 树必须显式给 CROSS_COMPILE, 否则 clang 编 x86_64★ ----
#   依据 Makefile:590-591
#       ifneq ($(CROSS_COMPILE),)
#       CLANG_FLAGS += --target=$(notdir $(CROSS_COMPILE:%-=%))
#   ⇒ 而 LLVM=1 时 CC 恒为裸 `clang`(Makefile:461 那段的 ifneq ($(LLVM),) 分支),
#     没有 CROSS_COMPILE 就没人给 clang 传 --target, clang 按宿主 x86_64 编译,
#     第一个倒下的就是 arch/arm64/kernel/asm-offsets.s:
#         asm/stack_pointer.h: register 'sp' unsuitable for global register variables
#         asm/kgdb.h: value '1025' out of range for constraint 'I'
#   为什么 LineageOS/高通树 `LLVM=1` 裸跑就行? 它们有 scripts/basic/cc-wrapper
#   (los Makefile:540 `CC := scripts/basic/cc-wrapper $(CC)`) 自动补 target。
#   纯 AOSP 树没有这东西 ⇒ 我们不抄它, 直接给标准 CROSS_COMPILE。
#   ⚠ 必须在 [4/8] 生成 .config 之前确定: olddefconfig 会拿 CC 探针的结果去定
#     CONFIG_BROKEN_GAS_INST / CONFIG_CC_HAS_K_CONSTRAINT / CONFIG_AS_HAS_*,
#     config 生成时用错编译器 ⇒ 整套 .config 都是脏的。
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
LLVM_IAS="${LLVM_IAS:-1}"     # 用 clang 集成汇编器, 绕开 GNU as 版本代差
TRIPLE="${CROSS_COMPILE%-}"   # aarch64-linux-gnu-  ->  aarch64-linux-gnu
export CROSS_COMPILE LLVM_IAS
log "CROSS_COMPILE=$CROSS_COMPILE (--target=$TRIPLE)  LLVM_IAS=$LLVM_IAS"
command -v "${CROSS_COMPILE}as" >/dev/null || warn "PATH 里没有 ${CROSS_COMPILE}as (LLVM_IAS=1 时不需要; 若改成 0 就需要装 binutils-aarch64-linux-gnu)"

# ---- 工具链探针: 30 毫秒级, 把"编不了 arm64"这件事在 defconfig 之前就捅破 ----
PROBE_DIR="$(mktemp -d)"
printf 'int f(void){register unsigned long sp asm ("sp"); return (int)sp;}\n' > "$PROBE_DIR/p.c"
printf '.text\n.global _p\n_p:\n\thint #0x22\n\tret\n' > "$PROBE_DIR/p.S"
case "$LLVM_IAS" in 1) PROBE_IAS=(-fintegrated-as) ;; *) PROBE_IAS=(-fno-integrated-as) ;; esac
probe_cc() { clang --target="$TRIPLE" "${PROBE_IAS[@]}" -c "$1" -o /dev/null 2>"$PROBE_DIR/err"; }
probe_cc "$PROBE_DIR/p.c" || die "clang 无法给 $TRIPLE 编译 C: $(head -3 "$PROBE_DIR/err" | tr '\n' ' ')"
probe_cc "$PROBE_DIR/p.S" || die "clang 无法汇编 $TRIPLE 的 .S: $(head -3 "$PROBE_DIR/err" | tr '\n' ' ')"
# kbuild 用 `-isystem $(shell $(CC) -print-file-name=include)` 找 stddef.h,
# clang 若因 --gcc-toolchain 猜错而回一个相对路径, 后面会以 'stddef.h not found' 炸掉
PROBE_INC="$(clang --target="$TRIPLE" -print-file-name=include)"
case "$PROBE_INC" in /*) ;; *) die "clang -print-file-name=include 返回相对路径 '$PROBE_INC' (kbuild 的 -isystem 会崩)" ;; esac
[ -d "$PROBE_INC" ] || die "clang -print-file-name=include 指向不存在的目录: $PROBE_INC"
log "探针通过: C/汇编/include 三关全过 (include=$PROBE_INC)"
rm -rf "$PROBE_DIR"

# 所有 make 都要带上这两个变量(含 kernelversion/kernelrelease/defconfig —— 探针一致性)
GKI_MAKE=(ARCH=arm64 LLVM=1 "CROSS_COMPILE=$CROSS_COMPILE" "LLVM_IAS=$LLVM_IAS")

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
make "${GKI_MAKE[@]}" gki_defconfig >/dev/null

# ---- 工具链实战探针: 真跑一遍 prepare(as 会编那个失败过的 asm-offsets.s) ----
#   run#24 就死在这: asm-offsets.s 报
#     asm/stack_pointer.h: register 'sp' unsuitable for global register variables
#     asm/kgdb.h: value '1025' out of range for constraint 'I'
#   = clang 在按 x86_64 编。prepare 只要 1~2 分钟, 就能确认工具链真能出 arm64
#   目标文件; 比等 60 分钟编译到一半再炸划算得多。(顺带: prepare 也会生成
#   include/config/auto.conf, 后面 setlocalversion 就有的读了)
log "工具链实战探针: make prepare (内含踩过坑的 arch/arm64/kernel/asm-offsets.s)"
if ! make "${GKI_MAKE[@]}" -j"$(nproc)" prepare >.probe-prepare.log 2>&1; then
    { echo "E: 工具链实战探针失败 —— clang 没能产出 arm64 目标文件";
      grep -nE "error:|fatal error|Error [0-9]+" .probe-prepare.log | head -20;
      tail -20 .probe-prepare.log; } >&2
    die "prepare 探针失败 (CROSS_COMPILE=$CROSS_COMPILE LLVM_IAS=$LLVM_IAS)"
fi
[ -f arch/arm64/kernel/asm-offsets.s ] || die "prepare 过了但 asm-offsets.s 没生成, 工具链判定不可信"
log "探针通过: prepare OK, asm-offsets.s $(wc -c < arch/arm64/kernel/asm-offsets.s) 字节"

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
# 生成 config 时用的是哪个编译器, 直接决定 CONFIG_CC_IS_* / BROKEN_GAS_INST 等探针结果
grep -E '^CONFIG_CC_VERSION_TEXT=' .config | head -1 | sed 's/^/I:   /' || true
grep -E '^CONFIG_(CC_IS_CLANG|BROKEN_GAS_INST|ARM64_USE_LSE_ATOMICS)=' .config | sed 's/^/I:   /' || true

# ══════════════════════════════════════════════════ [5/8] 精确复刻版本串
log "===== [5/8] 复刻原厂 UTS_RELEASE ====="
KV_BASE="$(make -s "${GKI_MAKE[@]}" kernelversion 2>/dev/null | tail -1 || true)"
[ -n "$KV_BASE" ] || die "拿不到源码 KERNELVERSION(Makefile 里 VERSION/PATCHLEVEL/SUBLEVEL)"
log "源码基线 KERNELVERSION = $KV_BASE"
case "$STOCK_UTS" in
    "$KV_BASE"*) SUFFIX="${STOCK_UTS#"$KV_BASE"}" ;;
    *) die "原厂串 $STOCK_UTS 与源码基线 $KV_BASE 不匹配 —— 选错 tag 了? 请换 GKI_REF" ;;
esac
[ -n "$SUFFIX" ] || die "无法从 $STOCK_UTS 截出后缀"

# 拆出 -ab<构建号>: Makefile:1391 自己会补 "-ab$(BUILD_NUMBER)", 不能重复放进 LOCALVERSION
BUILD_NO=""
LOCALV_SUFFIX="$SUFFIX"
case "$SUFFIX" in
    *-ab[0-9]*) BUILD_NO="${SUFFIX##*-ab}"; LOCALV_SUFFIX="${SUFFIX%-ab*}" ;;
esac
[ -n "$LOCALV_SUFFIX" ] || die "LOCALVERSION 段为空, 无法复刻"
log "CONFIG_LOCALVERSION = '$LOCALV_SUFFIX'"
log "BUILD_NUMBER        = '${BUILD_NO:-(无)}'"
log "要构造的完整 release = ${KV_BASE}${LOCALV_SUFFIX}${BUILD_NO:+-ab${BUILD_NO}}"

# ---- (1) 装 CONFIG_LOCALVERSION + 关 LOCALVERSION_AUTO(git describe 自动追加) ----
./scripts/config --file .config --set-str LOCALVERSION "$LOCALV_SUFFIX"
./scripts/config --file .config --disable LOCALVERSION_AUTO
make "${GKI_MAKE[@]}" olddefconfig >/dev/null

# ---- (2) ★显式生成 include/config/auto.conf★(run#23 失败根因, 别删这条) ----
#   `make kernelrelease` 属 no-sync-config-targets(Makefile:289) ⇒ 走 config-build 分支,
#   既不包含也不生成 auto.conf; 而 scripts/setlocalversion:186 找不到它会 `exit 1`
#   (错误只走 stderr, 被 $( ) 吞掉) ⇒ 版本串退化成裸基线。必须显式 syncconfig。
make "${GKI_MAKE[@]}" syncconfig >/dev/null 2>&1 || true
[ -f include/config/auto.conf ] || die "make syncconfig 没能生成 include/config/auto.conf"
log "auto.conf 已就绪: $(grep '^CONFIG_LOCALVERSION' include/config/auto.conf || echo '!! 里面没有 CONFIG_LOCALVERSION')"

# ---- (3) 环境变量 ----
#   (a) LOCALVERSION "置空但已定义" ⇒ 抑制 setlocalversion:211 追加 '+'
#   (b) BUILD_NUMBER ⇒ 让 Makefile:1391 补出 "-ab<号>"
export LOCALVERSION=""
if [ -n "$BUILD_NO" ]; then export BUILD_NUMBER="$BUILD_NO"; fi

# ---- (4) 断言 ----
#   ★注意 `make kernelrelease` 的输出**不含** -ab<BUILD_NUMBER>:
#     kernelrelease 目标(Makefile:2027-2029)只拼 KERNELVERSION+setlocalversion;
#     "-ab$(BUILD_NUMBER)" 是 UTS_RELEASE 专属(Makefile:1390-1391, 进 utsrelease.h)。
#     所以这里断言的是 KERNELRELEASE, 完整 STOCK_UTS 的断言放在 [7/8](utsrelease.h + Image)。
EXPECTED_KREL="${KV_BASE}${LOCALV_SUFFIX}"
#   `|| true` 是给 set -e/pipefail 用的: make 失败也算"实得空串", 走诊断分支而不是直接崩
ACTUAL="$(make -s "${GKI_MAKE[@]}" kernelrelease 2>.krel.err | tail -1 || true)"
KREL_OVERRIDE=""
if [ "$ACTUAL" = "$EXPECTED_KREL" ]; then
    log "自然复刻成功: KERNELRELEASE = $ACTUAL"
    log "  ⇒ UTS_RELEASE = ${EXPECTED_KREL}${BUILD_NO:+-ab${BUILD_NO}}   (= $STOCK_UTS)"
else
    warn "自然复刻失败: 期望 '$EXPECTED_KREL'  实得 '$ACTUAL'"
    warn "  setlocalversion 直调输出 : '$( (sh scripts/setlocalversion .) 2>&1 || true )'"
    warn "  .config                  : $(grep -n '^CONFIG_LOCALVERSION' .config || echo '(无)')"
    warn "  auto.conf                : $(grep -n '^CONFIG_LOCALVERSION' include/config/auto.conf 2>/dev/null || echo '(无)')"
    warn "  include/config/kernel.release: $(cat include/config/kernel.release 2>/dev/null || echo '(无)')"
    warn "  make stderr(前5行)       : $(head -5 .krel.err 2>/dev/null | tr '\n' ' ')"
    if [ -f localversion ]; then warn "  源树根还有 localversion 文件! 内容=$(cat localversion)"; fi
    warn "→ 启用兜底: 用 make 命令行变量 KERNELRELEASE=$STOCK_UTS 钉死"
    warn "  (Makefile:367 是 KERNELRELEASE = \$(shell cat ...), 命令行变量优先级更高)"
    KREL_OVERRIDE="$STOCK_UTS"
    unset BUILD_NUMBER || true
fi

# ══════════════════════════════════════════════════ [6/8] 编译
log "===== [6/8] 编译 Image (共享核心 compile_kernel.sh) ====="
# 官方 clang 12 不需要 frame-larger-than 降级 ⇒ KCFLAGS 显式置空(保留变量以便覆盖)
EXTRA_MAKE=("CROSS_COMPILE=$CROSS_COMPILE" "LLVM_IAS=$LLVM_IAS")
if [ -n "$KREL_OVERRIDE" ]; then
    warn "本次编译用命令行变量 KERNELRELEASE=$KREL_OVERRIDE 钉死版本串"
    EXTRA_MAKE+=("KERNELRELEASE=$KREL_OVERRIDE")
fi
KCFLAGS="${KCFLAGS-}" bash "$ROOT/scripts/compile_kernel.sh" . Image "${EXTRA_MAKE[@]}"

# ══════════════════════════════════════════════════ [7/8] 装配 + 双重复核
log "===== [7/8] 装配 boot.img 并复核 ====="
IMAGE="$KERNEL_DIR/arch/arm64/boot/Image"
[ -f "$IMAGE" ] || die "没有 arch/arm64/boot/Image"
# 编译期真正生效的 UTS_RELEASE(include/generated/utsrelease.h 才是 linux_banner 的来源)
UTS_H="$KERNEL_DIR/include/generated/utsrelease.h"
[ -f "$UTS_H" ] || die "没有 include/generated/utsrelease.h"
log "utsrelease.h: $(grep UTS_RELEASE "$UTS_H")"
grep -qF "\"$STOCK_UTS\"" "$UTS_H" || die "utsrelease.h 里的 UTS_RELEASE 不是 $STOCK_UTS"
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
  echo "UTS_RELEASE     : $STOCK_UTS   (与原厂 boot.img banner 完全一致)"
  if [ -n "$KREL_OVERRIDE" ]; then
    echo "版本串注入方式  : 兜底 —— make 命令行变量 KERNELRELEASE=$KREL_OVERRIDE (自然复刻未成功)"
  else
    echo "版本串注入方式  : 自然 —— CONFIG_LOCALVERSION='$LOCALV_SUFFIX' + BUILD_NUMBER='${BUILD_NO:-}'"
  fi
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
