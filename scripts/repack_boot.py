#!/usr/bin/env python3
"""
Repack GKI boot v4 image: 复用设备原镜像 header，仅替换其中的内核段。

流程 = 解包产物(header.bin + ramdisk + boot_signature) + 新编译 Image.gz -> 重打包

用法:
  python3 repack_boot.py <Image.gz> <header.bin> <ramdisk> <boot_signature> <output>

示例:
  python3 scripts/repack_boot.py dist/Image.gz stock/header.bin stock/ramdisk stock/boot_signature dist/boot.img

说明:
  - header.bin 为设备现刷包 boot.img 解包得到的完整 1584B v4 header，
    本脚本原样复用，仅更新其中 kernel_size 字段（offset 8），其余字段
    （os_version / ramdisk_size / cmdline / name / 保留位等）全部保留。
  - 实测本设备 GKI v4 镜像布局为页对齐型: header(1584B) 补零到 4096,
    其后 kernel / ramdisk / boot_signature 各段均按 4096 页对齐,
    与原镜像布局逐字节一致（与 AOSP mkbootimg 输出一致）。
  - boot_signature 为空时将其 size 置 0（正常情况必须提供原 4096B 签名段）。
"""
import struct
import sys


def page_align(data: bytes) -> bytes:
    return data + b"\x00" * ((-len(data)) % 4096)


def main() -> None:
    if len(sys.argv) != 6:
        print(__doc__)
        sys.exit(1)

    kernel_path, header_path, ramdisk_path, sig_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    out_path = sys.argv[5]

    header = open(header_path, "rb").read()
    if len(header) != 1584:
        raise SystemExit(f"header.bin 长度异常: {len(header)} (预期 1584)")
    if header[0:8] != b"ANDROID!":
        raise SystemExit("header.bin magic 错误: 不是 ANDROID!")
    hv = struct.unpack_from("<I", header, 40)[0]
    if hv != 4:
        raise SystemExit(f"header_version 不是 4: {hv}")

    kernel = open(kernel_path, "rb").read()
    ramdisk = open(ramdisk_path, "rb").read()
    signature = open(sig_path, "rb").read()
    if not kernel:
        raise SystemExit("kernel 为空")
    if not ramdisk:
        raise SystemExit("ramdisk 为空")

    old_ksz = struct.unpack_from("<I", header, 8)[0]
    print(f"原 header: kernel_size={old_ksz} ({old_ksz/1024/1024:.2f} MB) "
          f"ramdisk_size={struct.unpack_from('<I', header, 12)[0]} "
          f"os_version=0x{struct.unpack_from('<I', header, 16)[0]:08x} "
          f"signature_size={struct.unpack_from('<I', header, 1580)[0]}")
    if len(kernel) > old_ksz:
        print(f"WARN: 新内核 {len(kernel)}B 大于原内核 {old_ksz}B，可能导致分区放不下")

    # ---- 复用原 header，仅更新 kernel_size 与 boot_signature_size ----
    hdr = bytearray(header)
    struct.pack_into("<I", hdr, 8, len(kernel))          # 新内核大小
    struct.pack_into("<I", hdr, 1580, len(signature))    # 签名段大小（为空则 0）

    # ---- 页对齐布局: header 补零到 4096, 之后各段均 4096 对齐 ----
    img = bytes(hdr) + b"\x00" * ((-len(hdr)) % 4096)
    img += page_align(kernel)
    img += page_align(ramdisk)
    if signature:
        img += page_align(signature)

    with open(out_path, "wb") as f:
        f.write(img)

    print(f"OK: {out_path} ({len(img)} bytes)")
    print(f"  header   = 原镜像 1584B 原样复用(补 2512B 到页对齐), 仅更新 kernel_size")
    print(f"  kernel   = {len(kernel)} bytes (替换完成)")
    print(f"  ramdisk  = {len(ramdisk)} bytes (原样保留)")
    print(f"  boot_sig = {len(signature)} bytes (原样保留)")


if __name__ == "__main__":
    main()
