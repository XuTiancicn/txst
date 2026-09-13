# marble 定制 Droidian —— 性能解锁 / OpenSSH / 桌面环境可选

目标设备：**Redmi Note 12 Turbo / POCO F5（marble，SM7475）**
上游：[droidian-marble](https://github.com/droidian-marble)

本目录把用户要的五件事，**全部落到上游源码/配方层面**（不碰设备、不手改运行时）：

| # | 需求 | 落点（源码级） |
|---|---|---|
| 1 | 禁用安卓侧温控 + 其它压 CPU 的旋钮 | ① `droid-vendor-overlay/etc/thermal-{engine,normal}.conf` 中立化（覆盖安卓 `/vendor`）<br>② `usr/bin/droidian-perf.sh` 里 `ctl.stop` + 兜底 pkill 停掉安卓温控守护<br>③ 内核 defconfig 关降频类 thermal governor、尝试关 LMH/core_ctl/mi_* |
| 2 | Linux 调速器默认最高性能 | ① 内核 `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y`（默认即 performance）<br>② `droidian-perf.sh` 开机 oneshot 顶格<br>③ `marble-perf-guard.timer` **60s 幂等保活**（防安卓侧回写） |
| 3 | 桌面环境为**可选项** | 新增 edition `droidian_minimal.yaml`（无 phosh/cutie，纯服务端），<br>与官方 `phosh` 并列，`workflow_dispatch` 里二选一或都编 |
| 4 | 允许 SSH（OpenSSH） | 装 `openssh-server` + 开机 `systemctl enable ssh`（postinst + polish 双保险） |
| 5 | 补充 Linux server 常用服务 | 包清单见 `custom/scripts/prepare-image.sh`（网络/诊断/运维/运行时 40+ 个） |

---

## 一、为什么必须是"远端仓库"

- 内核源码浅克隆 ~2GB、debos 整刷包 1.5–3GB —— 本地磁盘不够，也无需本地算力。
- 本仓库只存**几 KB 的脚本 + 配方**；所有克隆/编译/打包都在 GitHub Actions 完成。

## 二、链路上真正起作用的几个"注入点"（已逐层核实）

```
droidian-xiaomi-marble @ droidian        ← ★不是 trixie！trixie 里既没有 marble
 ├─ community_devices.yml                  条目、也没有 community_devices.yml
 │    ├─ type: rootfs → image               (整刷包必须是 image)
 │    ├─ use_internal_repository: true      → apt/ 变成 file:// 内部源 ★注入自定义 deb
 │    ├─ edition: phosh|minimal             桌面环境开关
 │    └─ packages: [...]                    → install-adaptation.sh 逐个 apt 装
 ├─ apt/                                   内部 apt 仓库（需 apt-ftparchive 生成 Packages）
 ├─ pre-overlay/                           rootfs 早期覆盖（社区 apt 源，保持不动）
 └─ rootfs-templates/                      debos 配方
      ├─ device.yaml → recipe: droidian_<edition>.yaml   ★drop-in 新 edition 即可
      └─ recipes/polish.yaml               最后一步收尾（追加 enable ssh 双保险）

adaptation-xiaomi-marble @ droidian      ← 设备适配包（.deb）
 ├─ usr/bin/droidian-perf.sh               ★调速器 / 关温控守护 落点
 ├─ usr/lib/systemd/system/                ☆新增保活 unit
 ├─ usr/lib/droid-vendor-overlay/etc/      ★覆盖安卓 /vendor → 温控 conf 落点
 └─ debian/{rules,postinst,changelog}      ★装新 unit / 开机 enable / 版本压过社区源
```

**版本细节（容易踩）**：adaptation 包来自社区源 `halhadus.github.io/droidian-packages`（2.1.0）。
我们必须把自定义包版本写成 `1:2.1.0+marble1`（**带 epoch**），否则 apt 仍会选社区包，改动全部失效。

## 三、怎么跑

Actions → **Build custom Droidian marble image (perf-max / SSH / DE optional)** → Run workflow

| 输入 | 说明 |
|---|---|
| `editions` | `both` / `phosh`（有桌面）/ `minimal`（纯服务端无桌面） |
| `build_kernel` | 是否同时出性能解锁内核 `boot.img` |
| `dev_branch` | 默认 `droidian` |

产出：
- Release `droidian-custom-<edition>-<run>` → 整刷 zip（解压后 `./flash_all.sh`）
- Release `kernel-perf-<run>` → `boot.img`（`fastboot flash boot_a/boot_b`）

## 四、安全边界（**故意没动的东西**）

关温控是为了性能，但不能把保命措施一起关掉：

| 保留项 | 原因 |
|---|---|
| `thermal-chg-only.conf`（充电热保护） | 关掉有**电池热失控**风险，不是性能问题 |
| 内核 DTS `critical` trip（约 115℃） | 硬件级紧急关机，最后一道闸 |
| `kgsl force_*`（GPU） | 反复写会触发 CX GDSC 反复切换 → UI 卡死（已验证） |

## 五、已知不确定项（上手先看构建日志）

1. **内核符号名**：`custom/kernel/perf.fragment` 里的 vendor 旋钮符号（LMH/core_ctl/mi_*）
   各内核线命名不同。构建日志会打印「解锁项最终取值」段，**以日志为准**；缺失符号只告警不报错。
2. **温控 conf 文件名**：QTI/Xiaomi 标准命名是 `thermal-engine.conf` / `thermal-normal.conf`，
   多给的文件不会有害（用不上而已）。首次上机建议 `ls /vendor/etc/thermal*` 核对一遍。
3. **保活 timer 是否会与安卓侧打架**：60s 幂等重写，若观察到异常可
   `systemctl disable marble-perf-guard.timer` 单独关掉（governor 仍是 performance）。
4. **无桌面版接入**：`minimal` 已重新 enable `mobian-usb-gadget`（upstream 的 `setup-gsi.sh`
   会关掉它），配 USB RNDIS 或 WiFi + SSH。默认账号 `droidian` / `1234`。

## 六、本地文件布局

```
custom/
├── overlay/                     → 覆盖进 adaptation 源码树
│   ├── usr/bin/droidian-perf.sh
│   └── usr/lib/systemd/system/marble-perf-guard.{service,timer}
├── rootfs-templates/
│   └── droidian_minimal.yaml    → drop-in 到 rootfs-templates/
├── kernel/perf.fragment         → 内核配置片段
└── scripts/
    ├── build-adaptation-deb.sh  → 编定制 deb
    ├── prepare-image.sh         → 改造设备仓库配方
    └── build-kernel-perf.sh     → 编性能解锁内核
```
