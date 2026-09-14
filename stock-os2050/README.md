# stock-os2050 —— 原厂 HyperOS `OS2.0.5.0.VMRCNXM` 的 boot 容器件

本目录是**远程构建的必需输入**：CI 在 GitHub 上跑，拿不到本机磁盘上的原厂包，
所以把重打包所需的三个「容器件」提前抽出来存进仓库（合计约 1.35 MB）。

**内核段不在本目录内** —— 内核由 AOSP 源码现编，本目录只提供「壳」。

## 来源

```
E:\marble_images_OS2.0.5.0.VMRCNXM_15.0\images\boot.img
  201326592 bytes (192 MiB = marble boot 分区大小)
  header_version = 4 / header_size = 1584 / os_version 0x18000189 (12.0.0, patch 2024-09)
  kernel_size    = 46848116  (44.68 MB, raw 未压缩 arm64 PE/COFF Image, 头 4D5A "MZ")
  ramdisk_size   = 1380091
  signature_size = 4096
  内核 banner    = 5.10.209-android12-9-00019-g4ea09a298bb4-ab12292661
                   clang 12.0.5 (Android r416183b)
```

## 文件

| 文件 | 大小 | 说明 |
|---|---|---|
| `header.bin` | 1584 B | 完整 boot v4 header；重打包时**原样复用**，仅改 `kernel_size` 字段 |
| `ramdisk` | 1380091 B | 原厂 ramdisk（GKI generic ramdisk）；原样保留 |
| `boot_signature` | 4096 B | 原厂 v4 boot_signature；原样保留 |
| `parts.json` | — | 各段大小 / sha256 / os_version，供脚本自校验 |

## 复现方式

```bash
python3 tools/probe_stock.py        <images_dir>          # 看结构 + 内核版本
python3 tools/extract_boot_parts.py <images_dir>/boot.img stock-os2050
```

脚本只读原厂包，绝不修改。提取后 `parts.json` 里的 sha256 会被构建脚本
（`scripts/build_gki_aosp.sh` 第 1 步）逐字节复核，防止容器件被替换。

## 设备树在哪？为什么不在这里

marble 走 GKI，设备树分两处，**本次改动都不碰**：

- `vendor_boot.img` 内嵌 `dtb`（6675381 B @ offset 32505856）—— 运行时的真实设备树
- `dtbo.img`（24117248 B，头部 magic `d7b7ab1e` = DTBO 表）—— 叠加层

换 GKI 内核只替换 `boot.img` 里的 `Image`，DTB/DTBO 保持原厂不变 ——
这也是 GKI 的设计意图（内核通用、设备树与厂商驱动在外）。

## 边界

- 本目录**只服务于「在原厂 HyperOS 上换内核」**；Droidian 那条线用的是
  `stock/`（来自官方 LOS boot 分区），两者不可混用。
- 内核段必须 **raw 未压缩**：实测原厂与官方 Droidian 镜像的内核段都是
  raw（头 `4D5A`），marble 的 ABL 不认 gzip 段（2026-09-09 实测：gzip 段刷入后
  卡第一屏、无 USB）。
