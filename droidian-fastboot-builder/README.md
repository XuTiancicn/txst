# Droidian marble — fastboot 整刷包自动构建器

把官方 `droidian-xiaomi-marble` 的 **Recovery-only** 产物，扩展为 Droidian 官方推荐的
**fastboot-flashable 整刷包**（`type: image`）。每次构建都重新克隆最新源码，云编译产出
含 `flash_all.sh` 的 zip。

## 背景（为什么需要它）

| 项目 | 内容 |
|---|---|
| 官方构建仓库 | [droidian-marble/droidian-xiaomi-marble](https://github.com/droidian-marble/droidian-xiaomi-marble)（CI 配置壳，fork 自 droidian-images/droidian） |
| marble 当前配置 | `community_devices.yml` → `type: rootfs`（只产 TWRP sideload zip） |
| 本工具做的事 | 每次 clone 最新 → 把 `type` 切成 `image` → 官方容器里 debos 构建 → 产出 fastboot 直刷 zip |
| 产物格式 | zip 内含 `data/boot.img`、`data/userdata.img`（LVM 布局 Droidian 系统）、`flash_all.sh` |

构建链路（已逐层核实）：

```
community_devices.yml (type:image)
  → generate_device_recipe.py → generated/droidian.yaml
  → debos --disable-fakemachine
      → rootfs-templates/device.yaml (output_type=image)
      → scripts/genimage.sh
          - rootfs 打包为 LVM userdata.img（persistent 128M / reserved 32M / rootfs 余量）
          - 从 rootfs /boot 拷出 boot.img → data/
          - android-image-flashing-template/template（flash_all.sh）
          - flash-bootimage 配置拼接 → data/device-configuration.conf
```

## 快速开始（云编译，推荐）

1. 把本目录推到你自己的 GitHub 仓库（可复用已有 `XuTiancicn/txst`，或新建）：
   ```
   git init && git add . && git commit -m "droidian fastboot builder"
   git remote add origin git@github.com:<你>/<repo>.git && git push -u origin main
   ```
2. 仓库页 **Actions → Build Droidian marble fastboot image → Run workflow**（默认 `image`/`trixie`）
3. 约 30–60 分钟后产物出现在 Release（tag `droidian-image-<run>`）和 Artifacts

每次 Run 都会 `git clone --depth 1 --branch trixie` 拉最新，无需改任何代码。

## 本地构建（Linux/WSL + Docker）

```bash
./scripts/build.sh                # image 整刷包（默认）
./scripts/build.sh rootfs         # 官方同款 recovery zip（不切类型）
```

## 刷入

```bash
unzip droidian-UNOFFICIAL-*-image-*.zip
cd droidian-UNOFFICIAL-*-image-*
# 手机进 fastboot 后二选一:
./flash_all.sh                    # 官方脚本（自动识别设备，交互确认）
# 或
./scripts/flash_marble.sh         # 直通版：boot_a+boot_b+userdata，无交互
```

> ⚠️ **会清空 userdata**：现有 `/data/rootfs.img`（TWRP sideload 版）与 Android 数据全部丢失。
> A/B 双槽请保持同一 Android 版本（README 官方要求）。

## 已知问题 & 下一步

1. **黑屏根因未变**：产物 `boot.img` 仍是官方 5.10.226 gki —— 该内核线没有 `msm_drm.ko`
   显示驱动（`CONFIG_DRM_MSM/SDE/DPU` 未开，techpack display 未编），刷完大概率依旧黑屏。
   此包的意义是拿到**官方推荐的干净 LVM 安装基线**，然后换内核：
   - 换 boot：用本包 `data/boot.img` 提取 ramdisk，替换成带显示驱动的内核
     （可复用已有 `repack_boot.py` 流程：stock header/ramdisk + 新 Image → 新 boot.img）
     再 `fastboot flash boot_a boot_b <新boot.img>`
   - 内核来源候选：Melt 线（5.10.238-Melt，display built-in 传闻待实证）、
     或自己编 xiaomi 完整树（含 techpack/display）编出 `msm_drm.ko`
2. **marble flash-bootimage conf 很简陋**（deb 内仅 3 行：`FLASH_ENABLED=no`、无 dtbo/vbmeta
   分区），`flash_all.sh` 会走非 A/B 分支 + 交互确认设备；分区名不对就用手动脚本。
3. 产物 zip ~1.5–3GB：Release 单文件上限 2GB，超了请从 Actions Artifacts（保留 7 天）下载。
4. 默认 x86 runner + qemu 模拟 arm64（容器 `next-amd64`）；若构建卡死可改用 arm runner +
   `next-arm64`（上游同款配置）。

## 参考

- 上游构建系统: https://github.com/droidian-images/droidian
- 设备配置: droidian-marble/droidian-xiaomi-marble `community_devices.yml`
- flashing 模板: droidian-releng/android-image-flashing-template
- Droidian: https://droidian.org · 支持群: https://t.me/linuxonmarble
