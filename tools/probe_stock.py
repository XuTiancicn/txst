#!/usr/bin/env python3
"""
探测原厂 fastboot 包里的 boot.img / vendor_boot.img 结构 + 真实内核版本。

用法:
  python3 tools/probe_stock.py <images_dir>

只读，不写任何东西到设备/镜像目录。
"""
import os
import struct
import sys
import re
import zlib

PAGE = 4096


def align(n):
    return (n + PAGE - 1) // PAGE * PAGE


def parse_boot(d):
    if d[:8] != b"ANDROID!":
        return None
    g = lambda off: struct.unpack_from("<I", d, off)[0]
    h = {
        "kernel_size": g(8),
        "ramdisk_size": g(12),
        "os_version_raw": g(16),
        "header_size": g(20),
        "reserved0": g(24),
        "header_version": g(40),
        "cmdline": d[56:56 + 512].split(b"\x00")[0].decode("utf8", "replace"),
        "signature_size": g(1580),
    }
    ov = h["os_version_raw"]
    h["os_version"] = f"{(ov >> 25) & 0x7f}.{(ov >> 18) & 0x7f}.{(ov >> 11) & 0x7f}"
    h["os_patch"] = f"{2020 + ((ov >> 4) & 0x7f)}-{(ov & 0xf):02d}"
    return h


def parse_vendor_boot(d):
    if d[:8] != b"VNDRBOOT":
        return None
    g = lambda off: struct.unpack_from("<I", d, off)[0]
    h = {
        "header_version": g(8),
        "page_size": g(12),
        "kernel_addr": g(16),
        "ramdisk_addr": g(20),
        "vendor_ramdisk_size": g(24),
        "cmdline": d[28:28 + 2048].split(b"\x00")[0].decode("utf8", "replace"),
        "tags_addr": g(2076),
        "name": d[2080:2080 + 16].split(b"\x00")[0].decode("utf8", "replace"),
        "header_size": g(2096),
        "dtb_size": g(2100),
        "dtb_addr": g(2104),
    }
    return h


def find_version(b):
    """在二进制里找 Linux version banner（LZ4 字面量通常原样保留）。"""
    pats = [
        rb"Linux version ([^\x00\xff\n]{10,200})",
    ]
    out = []
    for p in pats:
        for m in re.finditer(p, b):
            s = m.group(1).decode("utf8", "replace").strip()
            if s not in out:
                out.append(s)
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    d = sys.argv[1]
    for name in ("boot.img", "vendor_boot.img", "dtbo.img"):
        p = os.path.join(d, name)
        if not os.path.exists(p):
            print(f"--- {name}: 不存在 ---")
            continue
        size = os.path.getsize(p)
        with open(p, "rb") as f:
            head = f.read(64 * 1024)
        print(f"===== {name}  ({size} bytes = {size/1024/1024:.1f} MB) =====")

        if name == "boot.img":
            h = parse_boot(head)
        elif name == "vendor_boot.img":
            h = parse_vendor_boot(head)
        else:
            h = None
        if h:
            for k, v in h.items():
                print(f"  {k:22} = {v}")
        else:
            print(f"  (header 解析: 前 16B = {head[:16].hex()})")

        # 取内核段 / dtb 段并找版本串
        if name == "boot.img" and h:
            ksz = h["kernel_size"]
            with open(p, "rb") as f:
                f.seek(PAGE)
                kern = f.read(ksz)
            magic = kern[:4]
            guess = "raw(ARM64 Image)"
            if magic[:4] == b"\x02\x21\x4c\x18":
                guess = "LZ4"
            elif magic[:2] == b"\x1f\x8b":
                guess = "gzip"
            elif magic[:4] == b"\x28\xb5\x2f\xfd":
                guess = "zstd"
            elif magic[:6] == b"\xfd7zXZ\x00":
                guess = "xz"
            print(f"  kernel 段: {ksz} bytes ({ksz/1024/1024:.1f} MB)  压缩={guess}")
            vs = find_version(kern)
            for v in vs[:6]:
                print(f"  ★ Linux version: {v}")
            if not vs:
                # gzip 兜底：找 gzip 流解压后再找
                for m in re.finditer(rb"\x1f\x8b\x08", kern[: 8 * 1024 * 1024]):
                    off = m.start()
                    try:
                        dz = zlib.decompressobj(31)
                        out = dz.decompress(kern[off:off + 20 * 1024 * 1024], 64 * 1024 * 1024)
                        vs2 = find_version(out)
                        if vs2:
                            print(f"  ★ gzip@{off}: {vs2[0]}")
                            break
                    except Exception:
                        continue
        print()


if __name__ == "__main__":
    main()
