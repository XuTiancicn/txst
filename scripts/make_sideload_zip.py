#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_sideload_zip.py — 把 boot.img 打包成 TWRP 可 adb sideload 的 OTA zip。

产出 zip 结构:
  marble-kernel-<ver>-sideload.zip
  ├── META-INF/com/google/android/update-binary    (shell 脚本, 755)
  ├── META-INF/com/google/android/updater-script   (占位)
  └── boot.img                                      (原样, STORED)

update-binary 行为 (在 TWRP/OrangeFox 内执行):
  1. 解压自身 boot.img 到 /tmp
  2. 读取 ro.boot.slot / cmdline androidboot.slot_suffix 判定 A/B 槽
  3. 定位 by-name boot 分区 (boot_a / boot_b / boot)
  4. dd 写入 + sha256 回读校验

用法:
  python3 make_sideload_zip.py <boot.img> <out.zip> [version_tag]

示例:
  python3 scripts/make_sideload_zip.py dist/boot.img dist/marble-kernel-sideload.zip 5.10.226
"""
import sys
import zipfile

UPDATE_BINARY = r"""#!/sbin/sh
# marble kernel installer (TWRP / OrangeFox sideload)
# argv: $1=api $2=outfd $3=zipfile
OUTFD=$2
ZIPFILE=$3
ui_print() {
  echo "ui_print $1" >&$OUTFD
  echo "ui_print" >&$OUTFD
}

ui_print " "
ui_print "Marble Kernel Installer"
ui_print " "

TMP=/tmp/marble_kernel_install
rm -rf "$TMP"; mkdir -p "$TMP"

# ---- 1. 解压 boot.img ----
if command -v unzip >/dev/null 2>&1; then
  unzip -o "$ZIPFILE" boot.img -d "$TMP" >/dev/null 2>&1 \
    || { ui_print "E: unzip boot.img 失败"; exit 1; }
elif command -v busybox >/dev/null 2>&1; then
  busybox unzip -o "$ZIPFILE" boot.img -d "$TMP" >/dev/null 2>&1 \
    || { ui_print "E: busybox unzip 失败"; exit 1; }
else
  ui_print "E: 环境中没有 unzip"; exit 1
fi
[ -f "$TMP/boot.img" ] || { ui_print "E: zip 内缺少 boot.img"; exit 1; }

# ---- 2. 判定 A/B 槽 ----
SLOT=$(getprop ro.boot.slot 2>/dev/null)
[ -z "$SLOT" ] && SLOT=$(cat /proc/cmdline 2>/dev/null | tr ' ' '\n' | sed -n 's/^androidboot.slot_suffix=//p' | head -1)
case "$SLOT" in
  _a|a) SLOT=_a ;;
  _b|b) SLOT=_b ;;
  *)    SLOT= ;;
esac
ui_print "active slot: ${SLOT:-unknown(non-AB?)}"

# ---- 3. 定位 boot 分区 ----
BOOT=
if [ -n "$SLOT" ]; then
  for p in \
      /dev/block/bootdevice/by-name/boot$SLOT \
      /dev/block/by-name/boot$SLOT \
      /dev/block/platform/bootdevice/by-name/boot$SLOT; do
    [ -b "$p" ] && BOOT=$p && break
  done
fi
if [ -z "$BOOT" ]; then
  for p in /dev/block/bootdevice/by-name/boot /dev/block/by-name/boot; do
    [ -b "$p" ] && BOOT=$p && break
  done
fi
[ -z "$BOOT" ] && { ui_print "E: 找不到 boot 分区设备"; exit 1; }
ui_print "target: $BOOT"

# ---- 4. 写入 + 回读校验 ----
SZ=$(stat -c %s "$TMP/boot.img" 2>/dev/null || wc -c < "$TMP/boot.img")
SIG=$(sha256sum "$TMP/boot.img" | cut -d' ' -f1)
ui_print "boot.img: $SZ bytes"
ui_print "sha256: ${SIG%????????????????????????????????}"

if ! dd if="$TMP/boot.img" of="$BOOT" bs=4096 conv=fsync 2>/dev/null; then
  ui_print "E: 写入 $BOOT 失败"; exit 1
fi
sync

CNT=$(( (SZ + 4095) / 4096 ))
RCV=$(dd if="$BOOT" bs=4096 count=$CNT 2>/dev/null | sha256sum | cut -d' ' -f1)
if [ "$RCV" = "$SIG" ]; then
  ui_print "写入完成, 回读校验 OK"
else
  ui_print "E: 回读校验不一致 (期望 ${SIG:0:16}... 实得 ${RCV:0:16}...)"
  exit 1
fi

ui_print " "
ui_print "完成。重启即可使用新内核"
ui_print " (如需回退: 重刷官方 boot 或重装原内核)"
ui_print " "
exit 0
"""

UPATER_SCRIPT = "# marble kernel sideload installer (auto)\n"


def main() -> None:
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    boot_img, out_zip = sys.argv[1], sys.argv[2]
    ver = sys.argv[3] if len(sys.argv) > 3 else "custom"

    import os
    if not os.path.isfile(boot_img):
        print(f"E: boot.img 不存在: {boot_img}")
        sys.exit(1)

    with zipfile.ZipFile(out_zip, "w", allowZip64=True) as z:
        # update-binary: 可执行 shell (unix 0755)
        zi = zipfile.ZipInfo("META-INF/com/google/android/update-binary")
        zi.external_attr = 0o100755 << 16
        zi.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(zi, UPDATE_BINARY)

        # updater-script 占位
        zi = zipfile.ZipInfo("META-INF/com/google/android/updater-script")
        zi.external_attr = 0o100644 << 16
        zi.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(zi, UPATER_SCRIPT)

        # boot.img 原样存储 (快速 + 体积不膨胀)
        zi = zipfile.ZipInfo("boot.img")
        zi.external_attr = 0o100644 << 16
        zi.compress_type = zipfile.ZIP_STORED
        with open(boot_img, "rb") as f:
            z.writestr(zi, f.read())

    sz = os.path.getsize(out_zip)
    print(f"OK: {out_zip} ({sz/1024/1024:.1f} MB)  version={ver}")
    print("刷入: TWRP -> Advanced -> ADB Sideload -> adb sideload <zip>")


if __name__ == "__main__":
    main()
