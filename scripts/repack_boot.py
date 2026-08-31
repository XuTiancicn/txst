#!/usr/bin/env python3
"""
Repack GKI boot v4 image: 新编译内核 + 设备原 ramdisk + 原 boot_signature。

用法:
  python3 repack_boot.py <Image.gz> <ramdisk> <boot_signature> <os_version_hex> <output>

示例:
  python3 scripts/repack_boot.py dist/Image.gz stock/ramdisk stock/boot_signature 0x18000199 dist/boot.img

说明:
  - header_version = 4 (GKI boot v4)
  - 内核、ramdisk、boot_signature 各按 4096 页对齐
  - os_version 直接用原镜像的值(hex)，确保与设备 vendor 侧一致
  - 保留原 boot_signature 段(4096B)，镜像结构与设备现刷包完全一致
"""
import struct
import sys


def page_align(data: bytes) -> bytes:
    return data + b"\x00" * ((-len(data)) % 4096)


def main() -> None:
    if len(sys.argv) != 6:
        print(__doc__)
        sys.exit(1)

    kernel_path, ramdisk_path, sig_path = sys.argv[1], sys.argv[2], sys.argv[3]
    osv = int(sys.argv[4], 0)
    out_path = sys.argv[5]

    kernel = open(kernel_path, "rb").read()
    ramdisk = open(ramdisk_path, "rb").read()
    signature = open(sig_path, "rb").read()
    if not kernel:
        raise SystemExit("kernel 为空")
    if not ramdisk:
        raise SystemExit("ramdisk 为空")

    # ---- v4 header (1584 bytes) ----
    hdr = bytearray(1584)
    hdr[0:8] = b"ANDROID!"
    struct.pack_into("<I", hdr, 8, len(kernel))     # kernel_size
    struct.pack_into("<I", hdr, 12, len(ramdisk))   # ramdisk_size
    struct.pack_into("<I", hdr, 16, osv)            # os_version
    struct.pack_into("<I", hdr, 20, 1584)           # header_size
    struct.pack_into("<I", hdr, 40, 4)              # header_version
    struct.pack_into("<I", hdr, 1580, len(signature))  # boot_signature_size

    img = bytes(hdr) + page_align(kernel) + page_align(ramdisk)
    if signature:
        img += page_align(signature)

    with open(out_path, "wb") as f:
        f.write(img)

    print(f"OK: {out_path} ({len(img)} bytes)")
    print(f"  kernel   = {len(kernel)} bytes")
    print(f"  ramdisk  = {len(ramdisk)} bytes")
    print(f"  boot_sig = {len(signature)} bytes")
    print(f"  os_version = 0x{osv:08x}, header_version = 4")


if __name__ == "__main__":
    main()
