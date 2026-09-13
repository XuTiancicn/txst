#!/bin/bash
# =============================================================================
# marble 性能最大化（Droidian 源码级定制，覆盖上游同名文件）
#
#   droidian-perf.sh               全量：cpufreq 顶格 + 解绑限制 + 关停安卓侧温控
#   droidian-perf.sh --freq-only   仅 cpufreq 顶格（供 60s 保活 timer 调用）
#
# 设计约束（沿用本项目四条铁律，勿删）:
#   ① 幂等：先读再比再写，绝不无脑重复写 sysfs
#   ② 零 fork 优先：read 为 shell 内建，避免 $(cat|tr|sort|tail) 风暴
#   ③ 重操作不进热路径：关停安卓温控只在开机跑一次；保活 timer 只碰 cpufreq
#   ④ 任何失败都不阻断启动：set +e，全部静默兜底
#
# ⚠ 安全边界（改动前必读）:
#   · 内核 DTS 里的 critical trip（约 115℃ 硬件级紧急关机）**不在此脚本管辖范围**，
#     也未被本定制移除 —— 保留最后一道保命闸。
#   · 充电热保护（vendor thermal-chg-only.conf）**故意不动**，避免电池热失控。
#     本脚本只关"CPU 降频"这一类性能限制。
# =============================================================================
set +e

FREQ_ONLY=0
[ "${1:-}" = "--freq-only" ] && FREQ_ONLY=1

# 幂等写：w <path> <value>
w() {
    [ -e "$1" ] && [ -w "$1" ] || return 0
    local cur
    IFS= read -r cur < "$1" 2>/dev/null
    [ "$cur" = "$2" ] && return 0
    printf '%s\n' "$2" > "$1" 2>/dev/null
    return 0
}

# ------------------------------------------------------------------ 1. cpufreq
# governor=performance，并把 min/max 都顶到 scaling_available_frequencies 最高档。
#
# ★不能直接写 cpuinfo_max_freq：厂商 thermal/hw 限频时该档不在可用表内，写入会被
#   内核静默拒绝（实测 rc=0 但值不变）。必须"向下吸附到可用表里 ≤ 目标的最大值"。
for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] || continue
    w "$p/scaling_governor" performance
    avail=$(cat "$p/scaling_available_frequencies" 2>/dev/null)
    [ -n "$avail" ] || continue
    top=${avail##* }              # 可用表升序，取最后一档
    w "$p/scaling_max_freq" "$top"
    w "$p/scaling_min_freq" "$top"
done

[ "$FREQ_ONLY" = 1 ] && exit 0

# -------------------------------------------------- 2. 解绑其它压制性能的旋钮
# core_ctl：8 核常驻在线（min_cpus == max_cpus == 在线核数）
NCPU=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l)
if [ "${NCPU:-0}" -gt 0 ] && [ -d /sys/devices/system/cpu/core_ctl ]; then
    w /sys/devices/system/cpu/core_ctl/min_cpus "$NCPU"
    w /sys/devices/system/cpu/core_ctl/max_cpus "$NCPU"
fi

# devfreq（bus_dcvs: DDR/L3/LLCC/DDRQOS 等）：boost/min 顶到最高档
for d in /sys/class/devfreq/*; do
    [ -d "$d" ] || continue
    avail=$(cat "$d/available_frequencies" 2>/dev/null)
    [ -n "$avail" ] || continue
    top=${avail##* }
    w "$d/boost_freq" "$top"
    w "$d/min_freq"   "$top"
done

# 调度器：schedstats 纯 profiling 开销，关掉
w /proc/sys/kernel/sched_schedstats 0
# 安全加固（与上游一致）
w /proc/sys/dev/tty/ldisc_autoload 0
# GPU：保持出厂默认。★铁律：反复写 kgsl force_* 会触发 CX GDSC 反复切换 → UI 卡死
w /sys/class/kgsl/kgsl-3d0/force_no_nap 0
w /sys/class/kgsl/kgsl-3d0/force_bus_on 0
w /sys/class/kgsl/kgsl-3d0/force_clk_on 0
w /sys/class/kgsl/kgsl-3d0/force_rail_on 0

# ---------------------------------------- 3. 关停 Android 侧温控（Halium 容器）
# ① 首选：让 Android init 真正 stop 服务（走 ctl.stop，init 不会自动拉起）
# ② 兜底：直接按进程名杀（Halium 容器与宿主共享 PID namespace）
if command -v lxc-attach >/dev/null 2>&1; then
    lxc-attach -n android -- /system/bin/sh -c \
        'for s in thermal-engine mi_thermd thermald thermal_manager; do setprop ctl.stop $s; done' \
        >/dev/null 2>&1
fi
for n in thermal-engine mi_thermd thermald thermal_manager; do
    pkill -9 -x "$n" >/dev/null 2>&1
done
pkill -9 -f 'vendor/bin/thermal' >/dev/null 2>&1

exit 0
