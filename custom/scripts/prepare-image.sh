#!/usr/bin/env bash
# =============================================================================
# prepare-image.sh
#
# 目标：把上游 droidian-xiaomi-marble 拉下来，在**源码层面**改造成我们要的镜像配方：
#   · community_devices.yml : type rootfs->image / use_internal_repository=true
#                             / edition 可选 / 追加 server 包
#   · apt/                  : 放入定制 adaptation deb + 生成 Packages 索引（内部源）
#   · rootfs-templates/     : drop-in droidian_minimal.yaml（无桌面 edition）
#                             + polish.yaml 追加"开机 enable ssh"收尾
#   · pre-overlay/          : 保持上游（社区 apt 源）
#
# 用法：WORK=<dir> EDITION=<phosh|minimal> DEBS=<dir> ./prepare-image.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"        # custom/
WORK="${WORK:-$PWD/work}"
EDITION="${EDITION:-phosh}"
DEBS="${DEBS:-$PWD/out}"
DEV_REPO="${DEV_REPO:-https://github.com/droidian-marble/droidian-xiaomi-marble.git}"
# ★必须是 droidian 分支：trixie 分支里没有 marble 条目，也没有 community_devices.yml
DEV_BRANCH="${DEV_BRANCH:-droidian}"

log() { echo "I: $*"; }
warn() { echo "W: $*" >&2; }
die() { echo "E: $*" >&2; exit 1; }

[ -d "$DEBS" ] || die "找不到 deb 目录: $DEBS"
mkdir -p "$WORK"
cd "$WORK"

log "== clone $DEV_REPO @ $DEV_BRANCH =="
rm -rf src
git config --global --get http.proxy >/dev/null 2>&1 && git config --global --unset http.proxy || true
git config --global --get https.proxy >/dev/null 2>&1 && git config --global --unset https.proxy || true
git clone --depth 1 --branch "$DEV_BRANCH" "$DEV_REPO" src
cd src
echo "上游 HEAD: $(git rev-parse --short HEAD)"
[ -f community_devices.yml ] || die "community_devices.yml 不存在（分支选错了？必须是 droidian）"

log "== submodule（debos 配方 + flashing 模板） =="
git submodule update --init --recursive
git submodule status

# ------------------------------------------------- 0.5 rootfs 容量策略
# ★默认「动态容量」——不用改任何配方：
#   上游 rootfs-templates/scripts/genimage.sh 建的是**小镜像**
#       IMG_SIZE = du -sm(rootfs) + 250 + 32 + 32   (MiB)
#   并在 rootfs 里打标记 /var/lib/halium/requires-lvm-resize，
#   首次启动由 halium init 把 LVM PV/LV 扩到 **userdata 分区满**。
#   上游 droidian-images/droidian README 原文：
#       "Fastboot-flashable images ... make use of the whole userdata partition."
#   ⇒ 256GB 机型刷完就是 ~230+ GiB 的 rootfs。
#   ★物理上限：fastboot flash userdata 的镜像不能大于 userdata 分区，
#     所以"做 256GB 镜像"既没必要也不可能（256GB 机型 userdata ≈230–238 GiB）。
#
# 固定容量兜底（ROOTFS_SIZE_GB=N，例如 100）：动态扩容万一在某设备失灵时用。
ROOTFS_SIZE_GB="${ROOTFS_SIZE_GB:-}"
GENIMAGE="rootfs-templates/scripts/genimage.sh"
if [ -n "$ROOTFS_SIZE_GB" ]; then
    log "== rootfs 固定容量: ${ROOTFS_SIZE_GB} GiB =="
    [ -f "$GENIMAGE" ] || die "找不到 $GENIMAGE"
    case "$ROOTFS_SIZE_GB" in
        ''|*[!0-9]*) die "ROOTFS_SIZE_GB 必须是整数（GiB），当前='$ROOTFS_SIZE_GB'" ;;
    esac
    [ "$ROOTFS_SIZE_GB" -le 220 ] || warn "!! ${ROOTFS_SIZE_GB} GiB 很可能大于 userdata 分区（256GB 机型 ≈230–238 GiB）⇒ fastboot 会报 image too large"
    python3 - "$ROOTFS_SIZE_GB" <<'PYEOF'
import io, re, sys
gb = int(sys.argv[1]); mib = gb * 1024
p = "rootfs-templates/scripts/genimage.sh"
s = io.open(p, encoding="utf-8").read()
if "MARBLE_FIXED_SIZE" in s:
    print("I:   genimage.sh 已打过补丁，跳过"); raise SystemExit(0)
s2 = re.sub(r'IMG_SIZE=\$\(\([^\n]*\)\)[^\n]*',
            'IMG_SIZE=%d # MARBLE_FIXED_SIZE (%d GiB)' % (mib, gb), s, count=1)
if s2 == s:
    sys.exit("E: genimage.sh 里找不到 IMG_SIZE=... 行（上游配方变了，请更新本补丁）")
s3 = s2.replace(
    'dd if=/dev/zero of=${WORK_DIR}/userdata.raw bs=1M count=${IMG_SIZE}',
    'truncate -s ${IMG_SIZE}M ${WORK_DIR}/userdata.raw # MARBLE_FIXED_SIZE(稀疏文件, 不真写零)')
if s3 == s2:
    sys.exit("E: genimage.sh 里找不到 dd 建 userdata.raw 的行（上游配方变了，请更新本补丁）")
io.open(p, "w", encoding="utf-8", newline="\n").write(s3)
print("I:   genimage.sh 已改为固定 %d MiB（稀疏文件）" % mib)
PYEOF
    grep -n 'IMG_SIZE=\|userdata.raw' "$GENIMAGE"
else
    log "== rootfs 动态容量（默认） =="
    log "   小镜像 + 首启 requires-lvm-resize 扩到 userdata 分区满（上游设计，无需改配方）"
    if grep -q 'requires-lvm-resize' "$GENIMAGE"; then
        grep -n 'IMG_SIZE=\|requires-lvm-resize' "$GENIMAGE" | sed 's/^/I:   /'
    else
        warn "!! genimage.sh 里没有 requires-lvm-resize 标记 —— 首启自动扩容可能失效"
        warn "   若刷完 df 发现 rootfs 太小，用 ROOTFS_SIZE_GB=100 出固定容量版本"
    fi
fi

# ------------------------------------------------------------------ 1. 内部 apt 源
log "== 注入定制 deb 到 apt/ （内部仓库） =="
rm -f apt/.dummy
cp -v "$DEBS"/*.deb apt/
( cd apt && apt-ftparchive packages . > Packages && gzip -kf Packages )
ls -lh apt/

# ------------------------------------------------------- 2. drop-in 新 edition
log "== drop-in droidian_minimal.yaml（无桌面 edition） =="
cp -v "$HERE/rootfs-templates/droidian_minimal.yaml" rootfs-templates/droidian_minimal.yaml
ls -1 rootfs-templates/droidian_*.yaml

# ----------------------------- 3. polish.yaml 追加收尾：开机 enable ssh/保活 timer
log "== polish.yaml 追加 enable 收尾 =="
POLISH=rootfs-templates/recipes/polish.yaml
if grep -q 'marble custom' "$POLISH"; then
    log "  已含 marble custom 段，跳过"
else
    cat >> "$POLISH" <<'EOF'

  # ---- marble custom: 保证 OpenSSH / 性能保活 timer 开机自启 ----
  # 不依赖包 postinst 的执行顺序，双保险（chroot 内 enable 失败则手建 symlink）
  - action: run
    chroot: true
    description: marble custom enable ssh + perf guard
    command: |
      systemctl enable ssh.service 2>/dev/null \
        || ln -sf /lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service
      systemctl enable marble-perf-guard.timer 2>/dev/null \
        || ln -sf /lib/systemd/system/marble-perf-guard.timer /etc/systemd/system/timers.target.wants/marble-perf-guard.timer
      systemctl enable droidian-perf.service 2>/dev/null \
        || ln -sf /lib/systemd/system/droidian-perf.service /etc/systemd/system/multi-user.target.wants/droidian-perf.service
EOF
    echo "--- polish.yaml 追加后 ---"
    tail -20 "$POLISH"
fi

# ------------------------------------------------- 4. 改 community_devices.yml
log "== 改造 xiaomi_marble 配方（type/内部源/edition/包列表） =="
python3 - "$EDITION" <<'PYEOF'
import io, re, sys

EDITION = sys.argv[1]
# ★ 这些包会被 debos 的 apt 动作**当成一个事务整体求解** —— 只要有一对
#   Provides/Conflicts 打起来，apt 就判定"整个请求不可满足"，连 openssh-common
#   这种基础包都会一起被列进 "not going to be installed"（日志极具误导性）。
#   已实测炸过一次：
#     E: Unable to satisfy dependencies. Reached two conflicting assignments:
#        chrony is selected for install / systemd-timesyncd Conflicts: time-daemon
#
#   ★ 关键：chrony 不是我们加的，是**上游默认**就装的（debos 日志里能看到
#     "Creating user '_chrony'" 与 "Setting up chrony"，上游 community_devices.yml
#     的包列表里也有它）。所以时间同步**已经由 chrony 提供**，
#     这里绝不能再列 chrony / systemd-timesyncd / any time-daemon 提供者。
#   ★ 另注意：本列表会与上游列表**合并成同一个 apt 事务**整体求解，
#     任何一对 Provides/Conflicts 打起来，apt 就把整批包（连 openssh-common、
#     python3、git 这些无关的）一起列进 "not going to be installed" —— 极具误导性，
#     定位时必须一路往日志下面看到最后那句 "E: Unable to satisfy dependencies"。
SERVER_PKGS = [
    # OpenSSH（"允许 ssh 连接，使用 OpenSSH"）
    "openssh-server", "openssh-client",
    # Linux server 常用服务/工具
    "sudo", "curl", "wget", "gnupg", "unzip", "zip", "tar",
    "vim-tiny", "nano", "bash-completion", "man-db",
    "procps", "psmisc", "htop", "lsof", "strace", "tmux", "screen",
    "net-tools", "iproute2", "iputils-ping", "dnsutils", "traceroute",
    "netcat-openbsd", "rsync", "git", "jq",
    # ★ 时间同步：不列！上游已装 chrony（列 systemd-timesyncd 会硬冲突）
    "iptables", "nftables",
    "cron", "logrotate",
    "python3", "python3-pip", "python3-venv",
]

path = "community_devices.yml"
lines = io.open(path, encoding="utf-8").read().splitlines()

# 定位 xiaomi_marble: 块（到下一个顶格 key 为止）
start = next((i for i, l in enumerate(lines) if re.match(r'^xiaomi_marble:\s*$', l)), None)
if start is None:
    sys.exit("E: community_devices.yml 里找不到 xiaomi_marble:")
end = next((j for j in range(start + 1, len(lines))
            if lines[j] and not lines[j][0].isspace()), len(lines))

block = lines[start:end]
out, pkgs, inserted_pkgs = [], [], False

for idx, l in enumerate(block):
    if re.match(r'^\s*type:\s*rootfs\s*$', l):
        out.append(re.sub(r'(\S+)\s*$', 'image', l)); continue
    if re.match(r'^\s*use_internal_repository:\s*', l):
        out.append(re.sub(r'(\S+)\s*$', 'true', l)); continue
    if re.match(r'^\s*edition:\s*', l):
        out.append(re.sub(r'(\S+)\s*$', EDITION, l)); continue
    if re.match(r'^\s*packages:\s*$', l):
        inserted_pkgs = True
        out.append(l)
        out.extend('    - %s' % p for p in SERVER_PKGS)
        continue
    out.append(l)

# 补 use_internal_repository（原块没有时）
if not any(re.match(r'^\s*use_internal_repository:', x) for x in out):
    for i, x in enumerate(out):
        if re.match(r'^\s*apilevel:', x):
            out.insert(i + 1, '  use_internal_repository: true')
            break
if not inserted_pkgs:
    sys.exit("E: xiaomi_marble 块里没有 packages: 段")

lines[start:end] = out
io.open(path, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
print("改造后 xiaomi_marble 块：")
print("\n".join(lines[start:start + 12 + len(SERVER_PKGS) + 4]))
PYEOF

log "== 校验：marble 配方关键字段 =="
grep -n -A4 '^xiaomi_marble:' community_devices.yml
grep -c '^    - ' community_devices.yml

log "OK: 配方就绪 -> $WORK/src  (edition=$EDITION)"
