#!/usr/bin/env python3
"""
从原厂 fastboot 包的 boot.img 里提取「容器件」（不含内核），供远端重打包复用。

用法:
  python3 tools/extract_boot_parts.py <boot.img> <outdir>

产物:
  header.bin        完整 1584B boot v4 header（含原 os_version / 各段大小）
  ramdisk           原 ramdisk（GKI generic ramdisk，按原样）
  boot_signature    v4 boot_signature（4096B）
  parts.json        元数据（版本串 / 大小 / sha256 / os_version）

只读源文件，绝不修改原厂包。
"""
import hashlib
import json
import os
import struct
import sys

PAGE = 4096


def align(n):
    return (n + PAGE - 1) // PAGE * PAGE


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    src, outdir = sys.argv[1], sys.argv[2]
    with open(src, "rb") as f:
        head = f.read(64 * 1024)
    if head[:8] != b"ANDROID!":
        raise SystemExit(f"{src}: 不是 ANDROID! boot 映像")

    g = lambda off: struct.unpack_from("<I", head, off)[0]
    ksz = g(8)
    rsz = g(12)
    osv_raw = g(16)
    hsz = g(20)
    hv = g(40)
    sigsz = g(1580)
    if hv != 4:
        raise SystemExit(f"header_version={hv}，本脚本只处理 v4")

    ov = osv_raw
    os_version = f"{(ov >> 25) & 0x7f}.{(ov >> 18) & 0x7f}.{(ov >> 11) & 0x7f}"
    os_patch = f"{2000 + ((ov >> 4) & 0x7f)}-{(ov & 0xf):02d}"

    k_off = PAGE
    r_off = align(k_off + ksz)
    s_off = align(r_off + rsz)

    with open(src, "rb") as f:
        f.seek(r_off)
        ramdisk = f.read(rsz)
        f.seek(s_off)
        signature = f.read(sigsz)

    os.makedirs(outdir, exist_ok=True)
    parts = {
        "source": os.path.basename(os.path.dirname(src.rstrip("/\\"))),
        "source_boot_img_size": os.path.getsize(src),
        "header_version": hv,
        "header_size": hsz,
        "os_version_raw": f"0x{osv_raw:08x}",
        "os_version": os_version,
        "os_patch_level": os_patch,
        "kernel_size_stock": ksz,
        "ramdisk_size": rsz,
        "boot_signature_size": sigsz,
        "ramdisk_sha256": sha256(ramdisk),
        "boot_signature_sha256": sha256(signature),
    }

    for name, blob in (("header.bin", head[:hsz]), ("ramdisk", ramdisk),
                       ("boot_signature", signature)):
        p = os.path.join(outdir, name)
        with open(p, "wb") as f:
            f.write(blob)
        print(f"  {name:16} {len(blob):>9} bytes  sha256={sha256(blob)[:16]}")

    # newline="\n": Windows 上默认会把 \n 翻成 \r\n, 而 .gitattributes 没覆盖 .json
    # ⇒ 显式写 LF, 保证仓库内与 CI 侧逐字节一致
    with open(os.path.join(outdir, "parts.json"), "w", encoding="utf8", newline="\n") as f:
        json.dump(parts, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print()
    for k, v in parts.items():
        print(f"  {k:24} = {v}")


if __name__ == "__main__":
    main()
