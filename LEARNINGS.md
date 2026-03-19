# Learnings — MSM8909 CAF 4.4 Port

Hard-won insights from porting MSM8909 from 3.18 to 4.4. Each section documents a problem that was non-obvious and the reasoning behind the fix.

## Kconfig Symbol Renames (3.18 → 4.4)

CAF renamed many config symbols. The defconfig silently ignores unknown symbols, so stale names cause features to be disabled without warning.

| 3.18 name | 4.4 name | Effect if wrong |
|-----------|----------|-----------------|
| `MSM_BUS_SCALING` | `QCOM_BUS_SCALING` | No bus bandwidth voting — DDR/SNOC unmanaged, PMIC brownout risk |
| `BUS_TOPOLOGY_ADHOC` | (removed, built unconditionally) | Harmless — just ignored |
| `MSM_SCM` | `QCOM_SCM` | No secure channel — SCM calls fail |

**Rule**: Always verify against `output/.config`, not just the defconfig.

## Non-PSCI Idle Path

The 4.4 LPM levels driver (`drivers/cpuidle/lpm-levels.c`) was designed for PSCI platforms (MSM8996+). MSM8909's TrustZone firmware does NOT implement PSCI — it uses legacy SCM-based CPU power management.

**Symptoms**: `usleep()`/`nanosleep()`/`sleep` hang forever. Busy-wait loops work. Boot timestamps appear normal (clocksource reads work, but clockevent interrupts may not fire properly).

**Root cause chain**:
1. `lpm_cpuidle_enter()` had `BUG_ON(!use_psci)` — panics on MSM8909
2. `psci_enter_sleep()` with `CONFIG_CPU_V7 && !CONFIG_ARM_PSCI` was a no-op stub
3. The 3.18→4.4 transition removed `on_each_cpu(setup_broadcast_timer)` that switched all CPUs to the frame timer for tick delivery

**Fix**: Ported the non-PSCI path from 3.18 (`msm-pm.c`, `idle-v7.S`, `pm-boot.c`). The dispatch goes through `msm_cpu_pm_enter_sleep()` which uses SCM calls (`scm_call_atomic1(SCM_SVC_BOOT, SCM_CMD_TERMINATE_PC, flag)`) for power collapse. Also restored broadcast timer setup at LPM probe time.

**How to tell if a SoC uses PSCI**: Check if `qcom,use-psci` is in the `qcom,lpm-levels` DTS node. MSM8909 does not have it. MSM8996, SDM660, MSM8998 do.

## Bus Scaling and PMIC Brownouts

Without `QCOM_BUS_SCALING`, no driver can vote for bus bandwidth via RPM. The DDR/SNOC/PCNOC fabrics run at whatever the bootloader set — no dynamic scaling. During sustained memory traffic, this can cause PMIC brownouts (experienced on kernel 6.19 before this was understood).

The full bandwidth management chain:
- `QCOM_BUS_SCALING` — bus fabric topology + RPM communication
- `QCOM_BIMC_BWMON` — hardware counters monitoring CPU-to-DDR traffic
- `DEVFREQ_GOV_QCOM_BW_HWMON` — devfreq governor that scales BIMC frequency based on bwmon
- `QCOM_DEVFREQ_DEVBW` — devfreq device for IB/AB bandwidth voting

DTS nodes: `cpubw` (devbw), `cpu-bwmon` (bimc-bwmon2 @ 0x408000), `devfreq-cpufreq` (CPU↔DDR freq mapping).

## DTS Compatible String Differences (3.18 → 4.4)

| Subsystem | 3.18 compatible | 4.4 compatible |
|-----------|----------------|----------------|
| USB OTG | `qcom,hsusb-otg` | `qcom,usb-otg-snps` |
| SPI QUP | `qcom,spi-qup-v2` | `qcom,spi-qup-v2.2.1` |
| SPI clocks | `"iface_clk","core_clk"` | `"core","iface"` |
| CPU enable-method | (machine smp_ops) | `qcom,kpss-acc-v2` |

## Timer DTS — Not the Problem

The MSM8909 timer DTS is identical between 3.18 and 4.4 and functionally equivalent to MSM8916. The `arm,armv7-timer` node with PPIs 2/3/4/1 and `arm,armv7-timer-mem` frame timer at 0xb020000 are correct. The timer hang was caused by the idle path, not the timer configuration.

## Boot Configuration

- No initramfs (for rootfs boot) — kernel mounts p36 directly
- Cmdline: `root=/dev/mmcblk0p36 rootfstype=ext4 rootwait rw console=tty0 console=ttyHSL0,115200`
- `.scmversion` file suppresses git hash in kernel version
- `FW_LOADER_USER_HELPER_FALLBACK` must be disabled — causes 60s hangs per firmware request

## Toolchain

GCC 7.4.1 (Linaro 2019.02). GCC 8+ breaks `BUILD_BUG_ON`/`compiletime_assert` — would need backporting ~5 commits from kernel 4.17+. GCC 4.9 works but is old.

## Build Fixes Applied

### Host (Debian 12 GCC)
- dtc: `extern YYLTYPE yylloc` (fixes -fno-common)
- scm.h: `static inline` on `scm_is_secure_device`
- gcc-wrapper.py: ported to python3, warnings disabled

### GCC 7/8
- Makefile: `-Wno-{attribute-alias,stringop-truncation,stringop-overflow,...}`
- compiler-gcc.h / compiler.h: disable `__compiletime_error` for GCC >= 8
- syscalls.h: disable `__SC_TEST BUILD_BUG_ON` for GCC >= 8

### Driver fixes
- wcnss_vreg.c: `regulator_set_optimum_mode` → `regulator_set_load`
- fbtft: `par->bl_dev` (not `fb_info`), removed `select FB_BACKLIGHT`
- soc/qcom Makefile: added `sysmon.o` for `CONFIG_MSM_SYSMON_COMM`
- APR: `SUBSYS_UP` → `SUBSYS_LOADED` in apr_v3.c (MSM8909 has no LPASS)
