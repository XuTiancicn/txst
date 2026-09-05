#!/usr/bin/env bash
#
# build.sh — 构建 Droidian marble fastboot-flashable 整刷包（含 flash_all.sh）
#
# 每次运行都会重新克隆最新的 droidian-xiaomi-marble（trixie）源码，
# 把 marble 配置从 type:rootfs（Recovery zip）切换为 type:image（fastboot 直刷），
# 在 Droidian 官方 rootfs-builder 容器内用 debos 构建，产物输出到 work/out/。
#
# 依赖: bash, git, docker（特权模式 + LVM + loop 设备支持）
# 用法:
#   ./scripts/build.sh                # 默认 image / trixie / next
#   ./scripts/build.sh rootfs         # 构建 recovery zip（不切换类型）
#   IMAGE_TYPE=rootfs ./scripts/build.sh
#
# 环境变量:
#   IMAGE_TYPE   image | rootfs         (默认 image)
#   BRANCH       上游分支                (默认 trixie)
#   VERSION      DROIDIAN_VERSION        (默认 next = nightly 命名)
#   SRC_REPO     克隆源                 (默认官方 droidian-marble/droidian-xiaomi-marble)
#   BUILDER_IMAGE 构建容器              (默认 quay.io/droidian/rootfs-builder:next-amd64)
#   WORK         工作目录               (默认 <repo>/work)
set -euo pipefail

IMAGE_TYPE="${IMAGE_TYPE:-image}"
BRANCH="${BRANCH:-trixie}"
VERSION="${VERSION:-next}"
SRC_REPO="${SRC_REPO:-https://github.com/droidian-marble/droidian-xiaomi-marble.git}"
BUILDER_IMAGE="${BUILDER_IMAGE:-quay.io/droidian/rootfs-builder:next-amd64}"
WORK="${WORK:-$(cd "$(dirname "$0")/.." && pwd)/work}"

log() { echo "I: $*"; }
err() { echo "E: $*" >&2; exit 1; }

[ "$IMAGE_TYPE" = image ] || [ "$IMAGE_TYPE" = rootfs ] || err "IMAGE_TYPE 必须是 image 或 rootfs"
command -v git >/dev/null || err "缺少 git"
command -v docker >/dev/null || err "缺少 docker"

log "== 参数 =="
log "  IMAGE_TYPE    = $IMAGE_TYPE"
log "  BRANCH        = $BRANCH"
log "  DROIDIAN_VERSION = $VERSION"
log "  SRC_REPO      = $SRC_REPO"
log "  BUILDER_IMAGE = $BUILDER_IMAGE"
log "  WORK          = $WORK"

rm -rf "$WORK"
mkdir -p "$WORK/out"

# ---------- 1. 每次都克隆最新源码 ----------
log "== 克隆最新 $SRC_REPO @ $BRANCH =="
git clone --depth 1 --branch "$BRANCH" "$SRC_REPO" "$WORK/src"
git -C "$WORK/src" submodule update --init --recursive
echo "--- 子模块锁定版本 ---"
git -C "$WORK/src" submodule status
echo "--- marble 当前配置 ---"
sed -n '/^xiaomi_marble:/,/^[a-z_0-9]*:/p' "$WORK/src/community_devices.yml" | head -20

# ---------- 2. 切换镜像类型 ----------
if [ "$IMAGE_TYPE" = image ]; then
    log "== 切换 marble: type rootfs -> image (fastboot-flashable) =="
    # community_devices.yml 中仅 xiaomi_marble 一个设备，替换其 type 字段
    sed -i -E '0,/^  type: rootfs/s//  type: image/' "$WORK/src/community_devices.yml"
    echo "--- 切换后 ---"
    grep -A3 '^xiaomi_marble:' "$WORK/src/community_devices.yml" | head -5
fi

# ---------- 3. 启动特权构建容器 ----------
log "== 启动构建容器 $BUILDER_IMAGE =="
docker pull "$BUILDER_IMAGE"
CID=$(docker run --detach --privileged --cgroupns=host \
    -v "$WORK/out:/buildd/out" \
    -v /dev:/host-dev \
    -v /sys/fs/cgroup:/sys/fs/cgroup \
    -v "$WORK/src:/buildd/sources" \
    --security-opt seccomp:unconfined \
    "$BUILDER_IMAGE" sleep infinity)
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT

# ---------- 4. 生成配方 + debos 构建 ----------
log "== 生成设备配方并构建（debos，耗时较长）=="
docker exec "$CID" /bin/sh -c '
    set -ex
    cd /buildd/sources
    export DROIDIAN_VERSION="'"$VERSION"'"
    ./generate_device_recipe.py xiaomi_marble arm64 phosh phone 32
    echo "===== generated/product.yaml ====="
    cat generated/product.yaml
    echo "===== generated/droidian.yaml ====="
    cat generated/droidian.yaml
    debos --disable-fakemachine generated/droidian.yaml
'
docker rm -f "$CID"
trap - EXIT

log "== 构建完成 =="
log "产物目录: $WORK/out/"
ls -lh "$WORK/out/" || true
log "刷入方式: 解压 zip -> 手机进 fastboot -> ./flash_all.sh"
