#!/usr/bin/env bash
# =============================================================================
# build-adaptation-deb.sh
#
# 目标：把上游 droidian-marble/adaptation-xiaomi-marble 拉下来，在**源码层面**
#       打上本定制（性能/温控/服务），编成 .deb 供镜像构建内部 apt 源使用。
#
# 为什么不用 fork：整条链路自包含在本仓库内，上游更新时 patch 失效会立刻暴露。
#
# 环境：ubuntu-latest（amd64 足够，本包 Architecture: all，无需交叉编译）
# 用法：WORK=<repo> OUT=<dir> ./build-adaptation-deb.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # custom/
WORK="${WORK:-$PWD/work}"
OUT="${OUT:-$PWD/out}"
ADAPT_REPO="${ADAPT_REPO:-https://github.com/droidian-marble/adaptation-xiaomi-marble.git}"
ADAPT_BRANCH="${ADAPT_BRANCH:-droidian}"
# ★ 版本必须压过社区源(halhadus.github.io/droidian-packages 的 2.1.0)，否则 apt 会
#   优先取社区包，我们的改动全白做。用 epoch=1 保证任何上游 2.x/3.x 都赢不过。
ADAPT_VERSION="${ADAPT_VERSION:-1:2.1.0+marble1}"

log() { echo "I: $*"; }
die() { echo "E: $*" >&2; exit 1; }

mkdir -p "$WORK" "$OUT"
cd "$WORK"

# ---------------------------------------------------------------- 0. 依赖
export DEBIAN_FRONTEND=noninteractive
need_pkgs=""
for c in dpkg-buildpackage dh; do command -v "$c" >/dev/null || need_pkgs="$need_pkgs debhelper"; done
[ -n "$need_pkgs" ] && { sudo apt-get update -qq; sudo apt-get install -y -qq $need_pkgs; }

# ---------------------------------------------------------------- 1. 取源码
log "== clone $ADAPT_REPO @ $ADAPT_BRANCH =="
rm -rf adapt
git config --global --get http.proxy >/dev/null 2>&1 && git config --global --unset http.proxy || true
git config --global --get https.proxy >/dev/null 2>&1 && git config --global --unset https.proxy || true
git clone --depth 1 --branch "$ADAPT_BRANCH" "$ADAPT_REPO" adapt
cd adapt
echo "上游 HEAD: $(git rev-parse --short HEAD)  $(git log -1 --pretty=%s)"

# ------------------------------------------------- 2. 覆盖 payload（源码级改动）
log "== 覆盖定制 payload =="
# usr/bin/droidian-perf.sh            ← 调速器最高性能 + 关停安卓温控
# usr/lib/systemd/system/*.service/timer ← 60s 保活
cp -rv "$HERE/overlay/." .
chmod 755 usr/bin/droidian-perf.sh

# --------------------- 3. 中立化安卓侧温控 conf（经 droid-vendor-overlay 覆盖 /vendor）
# ★安全边界：只中立化"常驻档" thermal-engine.conf / thermal-normal.conf。
#   充电热保护 thermal-chg-only.conf **故意不动**（电池热失控风险），
#   内核 DTS 的 critical trip（~115℃ 紧急关机）也不动。
log "== 中立化安卓侧温控 conf（保留充电热保护） =="
THERM_DIR=usr/lib/droid-vendor-overlay/etc
mkdir -p "$THERM_DIR"
for f in thermal-engine.conf thermal-normal.conf; do
    cat > "$THERM_DIR/$f" <<'EOF'
# ---------------------------------------------------------------------------
# 【marble custom】本文件被主动中立化：不含任何 sensor/action 规则。
# 目的：让 vendor thermal 守护无降温动作可执行 = 关掉 CPU 降频。
# 保留未动的文件：thermal-chg-only.conf（充电热保护，安全红线）
# 保命闸仍在：内核 DTS critical trip ~115℃ 硬件级紧急关机
# ---------------------------------------------------------------------------
EOF
    echo "  中立化: $THERM_DIR/$f"
done

# ------------------------------------------------ 4. 打包层面：装单元 + 开机 enable
log "== patch debian/rules =="
RULES=debian/rules
grep -q 'marble-perf-guard' "$RULES" && die "debian/rules 已含 marble-perf-guard（上游已合入？请复核）"
sed -i 's#\(dh_installsystemd -padaptation-xiaomi-marble-configs --no-start.*\)#\1 marble-perf-guard.service marble-perf-guard.timer#' "$RULES"
grep -n 'dh_installsystemd' "$RULES"

log "== patch debian/postinst =="
python3 - <<'PYEOF'
import io
p = "debian/postinst"
s = io.open(p, encoding="utf-8").read()
if "marble-perf-guard" in s:
    raise SystemExit("E: postinst 已含 marble-perf-guard，请复核上游是否已合入")
anchor = "    systemctl mask droidian-fpd\n"
if anchor not in s:
    raise SystemExit("E: postinst 里找不到锚点 'systemctl mask droidian-fpd'")
extra = (
    "\n"
    "    # --- marble custom: 常驻性能保活 + OpenSSH ---\n"
    "    systemctl enable marble-perf-guard.timer 2>/dev/null || true\n"
    "    systemctl enable ssh.service 2>/dev/null || \\\n"
    "        systemctl enable sshd.service 2>/dev/null || true\n"
)
s = s.replace(anchor, anchor + extra, 1)
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("postinst 已注入：")
print("\n".join(s.splitlines()[3:26]))
PYEOF

log "== bump debian/changelog -> $ADAPT_VERSION =="
{
    echo "adaptation-xiaomi-marble ($ADAPT_VERSION) UNRELEASED; urgency=medium"
    echo
    echo "  [ marble custom ]"
    echo "  * cpufreq 默认/保活 = performance（含 60s 幂等保活 timer）"
    echo "  * 中立化 vendor thermal-engine/normal.conf，关停安卓侧温控守护"
    echo "  * 解绑 core_ctl / devfreq boost 等性能旋钮"
    echo "  * 安装并开机启用 OpenSSH"
    echo
    echo " -- XuTiancicn <noreply@github.com>  $(date -R)"
    echo
} | cat - debian/changelog > debian/changelog.new
mv debian/changelog.new debian/changelog
head -12 debian/changelog

# ---------------------------------------------------------------- 5. 编包
log "== dpkg-buildpackage =="
dpkg-buildpackage -b -us -uc 2>&1 | tail -25
cd "$WORK"
ls -lh adapt_*.deb ../*.deb 2>/dev/null || true

log "== 收集产物 =="
find "$WORK" -maxdepth 2 -name '*.deb' -newermt '-30 minutes' -exec cp -v {} "$OUT/" \;
ls -lh "$OUT/"
echo "OK: 定制 adaptation 包 -> $OUT/"
