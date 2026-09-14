set -o pipefail
SRC="$PWD/work-src-${EDITION}"
# ★ 设备仓库在 $SRC/src（prepare-image.sh 克隆到这里），不是 $SRC 本身。
DSRC="$SRC/src"
mkdir -p "$SRC/out"
if [ ! -f "$DSRC/generate_device_recipe.py" ]; then
  echo "::error::$DSRC 下没有 generate_device_recipe.py"
  ls -la "$SRC" "$DSRC" 2>/dev/null || true
  exit 1
fi
CID=$(docker run --detach --privileged --cgroupns=host \
        -v "$SRC/out:/buildd/out" \
        -v /dev:/host-dev \
        -v /sys/fs/cgroup:/sys/fs/cgroup \
        -v "$DSRC:/buildd/sources" \
        --security-opt seccomp:unconfined \
        quay.io/droidian/rootfs-builder:next-arm64 sleep infinity)
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
set +e
docker exec "$CID" /bin/sh -c '
  set -ex
  cd /buildd/sources
  export DROIDIAN_VERSION="'"$DROIDIAN_VERSION"'"
  ./generate_device_recipe.py xiaomi_marble arm64 "'"${EDITION}"'" phone 32 ""
  echo "===== generated/droidian.yaml ====="; cat generated/droidian.yaml
  echo "===== rootfs 尺寸相关配方 (genimage.sh) ====="; grep -n "IMG_SIZE\|userdata.raw\|requires-lvm-resize" rootfs-templates/scripts/genimage.sh || true
  debos --disable-fakemachine generated/droidian.yaml
  cp -r /buildd/sources/out/. /buildd/out/ 2>/dev/null || true
  echo "===== /buildd/out ====="; ls -lh /buildd/out/ || true
' 2>&1 | tee debos.log
rc=${PIPESTATUS[0]}
set -e
tail -60 debos.log || true
if [ "$rc" -ne 0 ]; then
  echo "::error::debos 构建失败 rc=$rc"
  exit "$rc"
fi
