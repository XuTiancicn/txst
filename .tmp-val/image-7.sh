set -euo pipefail
SRC="$PWD/work-src-${EDITION}"
PKG="$PWD/dist"
rm -rf "$PKG"; mkdir -p "$PKG"
ZIP=$(ls "$SRC"/out/*.zip | head -1)
BASE=$(basename "$ZIP")
cp "$ZIP" "$PKG/$BASE"
echo "===== 上游产物 ====="; ls -lh "$SRC"/out/
echo "===== zip 内容 ====="; unzip -l "$PKG/$BASE"

# ★ 不整包解压：只把要新增的条目摆成相同相对路径，再用 zip -g 追加。
#   userdata.img 那几个大件原样保留，不重新压缩（省时间省磁盘）。
STAGE=$(mktemp -d)
mkdir -p "$STAGE/data"

if [ -f boot-gki.img ]; then
  cp boot-gki.img "$STAGE/data/boot-gki.img"
  cat > "$STAGE/flash_gki_kernel.sh" <<'EOS'
#!/usr/bin/env bash
# 只换内核：把 Google AOSP GKI 内核刷进 A/B 两个 boot 槽，不动 userdata。
# 上游那个 data/boot.img（Droidian 自带内核）保持原样，随时可以刷回去。
set -euo pipefail
[ -f data/boot-gki.img ] || { echo "E: 缺少 data/boot-gki.img" >&2; exit 1; }
command -v fastboot >/dev/null || { echo "E: 缺少 fastboot" >&2; exit 1; }
fastboot devices
fastboot flash boot_a data/boot-gki.img
fastboot flash boot_b data/boot-gki.img
fastboot reboot
echo "已刷入 GKI 内核并重启"
EOS
  chmod +x "$STAGE/flash_gki_kernel.sh"
  cat > "$STAGE/README-FLASH.md" <<'EOS'
# marble 完整系统整刷包（Droidian + GKI 内核）

## 一、整刷（会清空 userdata）
解压 → 手机关机 → 音量下+电源 进 fastboot → `./flash_all.sh`

首次启动会自动把 LVM 扩到 **userdata 分区满**（256GB 机型 → ~230+ GiB rootfs）。
默认解锁密码 `1234`。

## 二、只要换内核
`./flash_gki_kernel.sh` —— 把 `data/boot-gki.img` 刷进 boot_a/boot_b，不动 userdata。
想刷回 Droidian 自带内核：`fastboot flash boot_a data/boot.img`（boot_b 同理）。

## 三、包里都是什么
| 文件 | 说明 |
|---|---|
| `data/userdata.img` | Droidian 系统本体（LVM：persistent 32M / reserved 32M / rootfs） |
| `data/boot.img` | 上游 Droidian 内核（容器/ramdisk/签名原样，兜底用） |
| `data/boot-gki.img` | Google AOSP GKI 内核（原厂基线 v5.10.209，KMI android12-9） |
| `data/dtbo.img` / `data/vbmeta.img` | 如有则由上游带出 |
| `flash_all.sh` | 上游官方整刷脚本 |
EOS
else
  cat > "$STAGE/README-FLASH.md" <<'EOS'
# marble 完整系统整刷包（Droidian）

## 整刷（会清空 userdata）
解压 → 手机关机 → 音量下+电源 进 fastboot → `./flash_all.sh`

首次启动会自动把 LVM 扩到 **userdata 分区满**（256GB 机型 → ~230+ GiB rootfs）。
默认解锁密码 `1234`。

本次未注入 GKI 内核（没找到可用产物），包里内核为上游 Droidian 自带。
EOS
fi

ADD=(README-FLASH.md)
if [ -f "$STAGE/data/boot-gki.img" ]; then
  ADD+=(data/boot-gki.img flash_gki_kernel.sh)
fi
( cd "$STAGE" && zip -9 -g "$PKG/$BASE" "${ADD[@]}" )
echo "===== 追加后 zip 内容 ====="; unzip -l "$PKG/$BASE"

# Release 单文件上限 2 GiB ⇒ 超了自动分卷
SZ=$(stat -c%s "$PKG/$BASE")
echo "包大小: $SZ 字节 ($(( SZ / 1024 / 1024 )) MiB)"
if [ "$SZ" -gt $(( 2 * 1024 * 1024 * 1024 )) ]; then
  echo "::warning::超过 Release 2 GiB 单文件上限 → 分卷（1900 MiB/卷）"
  ( cd "$PKG" && zip -s 1900m "$BASE" --out "${BASE%.zip}-split.zip" )
  rm -f "$PKG/$BASE"
fi
( cd "$PKG" && sha256sum * > SHA256SUMS.txt && cat SHA256SUMS.txt )
ls -lh "$PKG"
