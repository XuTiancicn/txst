#!/usr/bin/env python3
"""
Unpack GKI boot v4 image: 从 boot.img 提取 header.bin / ramdisk / boot_signature，
供 repack_boot.py 重打包时复用（容器部件）。

用法:
  python3 unpack_boot_v4.py <boot.img> <outdir>

产物:
  <outdir>/header.bin         完整 1584B v4 header (含 signature_size 字段)
  <outdir>/kernel.bin         原内核段 (未压缩 Image 或压缩流, 按原样)
  <outdir>/ramdisk            原 ramdisk (lz4/gzip/cpio 按原样)
  <outdir>/boot_signature     v4 boot_signature (通常 4096B; 无则 0B 文件)

布局 (实测 GKI v4, mkbootimg 输出):
  [0, 4096)          header 1584B + 补零
  [4096, +ksz)       kernel (page 对齐起点)
  [... 页对齐 ...)   ramdisk
  [... 页对齐 ...)   boot_signature (若 signature_size > 0)
"""
import struct
import sys
import os


def page_align_up(n: int) -> int:
    return (n + 4095) // 4096 * 4096


def main() -> None:
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    img_path, outdir = sys.argv[1], sys.argv[2]
    d = open(img_path, "rb").read()
    if d[:8] != b"ANDROID!":
        raise SystemExit(f"{img_path}: 不是 ANDROID! boot 映像")

    kernel_size = struct.unpack_from("<I", d, 8)[0]
    ramdisk_size = struct.unpack_from("<I", d, 12)[0]
    header_version = struct.unpack_from("<I", d, 40)[0]
    sig_size = struct.unpack_from("<I", d, 1580)[0]
    if header_version != 4:
        raise SystemExit(f"header_version={header_version}, 仅支持 v4")

    header = d[:1584]
    k_off = 4096
    kernel = d[k_off:k_off + kernel_size]
    r_off = page_align_up(k_off + kernel_size)
    ramdisk = d[r_off:r_off + ramdisk_size]
    s_off = page_align_up(r_off + ramdisk_size)
    signature = d[s_off:s_off + sig_size] if sig_size else b""

    print(f"kernel_size={kernel_size} ({kernel_size/1024/1024:.1f} MB)")
    print(f"ramdisk_size={ramdisk_size} ({ramdisk_size/1024/1024:.2f} MB)")
    print(f"signature_size={sig_size}")
    print(f"kernel 头16B: {kernel[:16].hex()}")
    print(f"ramdisk 头16B: {ramdisk[:16].hex()}")

    os.makedirs(outdir, exist_ok=True)
    for name, data in [("header.bin", header), ("kernel.bin", kernel),
                       ("ramdisk", ramdisk), ("boot_signature", signature)]:
        with open(os.path.join(outdir, name), "wb") as f:
            f.write(data)
    print(f"OK: 4 部件已写入 {outdir}")


if __name__ == "__main__":
    main()
