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

## SMP — Fixed, All 4 CPUs Online

**Root cause**: Two issues in the 4.4 `arch/arm/mach-qcom/platsmp.c`:

1. **Wrong SCM boot address API**: The 4.4 Linaro SCM used `SCM_BOOT_ADDR` (cmd 0x01), but MSM8909's TZ primarily supports `SCM_BOOT_ADDR_MC` (cmd 0x11, multi-cluster). TZ disassembly confirms: BOOT_ADDR_MC has 39 references in the syscall descriptor table vs 7 for legacy BOOT_ADDR. The 3.18 kernel detects this via `scm_is_mc_boot_available()` and uses `scm_set_boot_addr_mc()`. Both buffer-based `scm_call()` and register-based `scm_call_atomic2()` fail with the legacy API (TZ returns -1).

2. **Wrong CPU release sequence**: The generic `kpssv2_release_secondary()` uses standard KPSS v2 register patterns (multi-step BHS/LDO + L2 SAW write) that don't match MSM8909 hardware. The 3.18 `arm_release_secondary()` uses a completely different 6-step sequence with custom bit patterns (including CORE_RST bit 4 and undocumented bit 17). The L2 SAW write at 0x0b01201c caused a hard lockup.

**Fix** (in `arch/arm/mach-qcom/platsmp.c`):
- Use `scm_set_boot_addr_mc()` from `<soc/qcom/scm-boot.h>` with MPIDR affinity masks
- Replace kpssv2 register sequence with 3.18's `arm_release_secondary` sequence (DT-based ACC lookup, no L2 SAW)

**TZ analysis** (from disassembly of tz.mbn):
- ACC/SAW register addresses (0x0b088000 etc.) are NOT in the TZ binary — CPU power management uses SCM API, but ACC registers are accessible from non-secure world
- TZ supports both legacy buffer-based and SMCCC calling conventions (`is_scm_armv8()` detects)
- The legacy `scm_call()` path works for `SCM_BOOT_ADDR_MC` but not `SCM_BOOT_ADDR`

## Modem PIL — DMA and Auth Fixes

The modem Q6 DSP PIL (Peripheral Image Loader) had two bugs on 4.4:

### DMA alloc hang (fixed)

`pil_mss_reset_load_mba()` calls `arch_setup_dma_ops(dma_dev, 0, 0, NULL, 0)` on a dummy `struct device` before allocating 1MB for MBA firmware. This call was added in 4.4 (not present in 3.18).

On ARM, `arch_setup_dma_ops` with `iommu=NULL` sets `arm_dma_ops`, which routes `dma_alloc_attrs(1MB)` through `alloc_pages(GFP_KERNEL, order=8)` instead of CMA. The order-8 buddy allocation blocks in memory compaction.

On 3.18, without `arch_setup_dma_ops`, the dummy device falls through to the default CMA allocator which handles 1MB easily.

**Fix**: Remove the `arch_setup_dma_ops()` call. Just set `coherent_dma_mask` like 3.18.

### Auth poll hang (fixed with SMP)

`pil_msa_mba_auth()` uses `readl_poll_timeout()` to wait for `STATUS_AUTH_COMPLETE`. With SMP working, a `mdelay(1) + cond_resched()` poll loop works (5.3s to complete). The auth succeeds with `status=4, ret=0`.

### err_ready wait (fixed with SMP)

After `pil_boot` completes, `subsystem_restart.c` calls `wait_for_err_ready()`. With SMP, the SMP2P err_ready signal arrives ~1s after modem reset. Made timeout non-fatal (warn instead of panic) for robustness.

### Modem Q6 watchdog — stalled initialization (open)

After successful PIL boot + auth, the modem Q6 starts running but its internal watchdog fires after ~40s: `dog.c:1522:Watchdog detects stalled initialization`. The Q6 DSP can't complete init — likely waiting for AP-side resources. `apr_register: Modem is not Up` confirms SMD/APR link never establishes. Triggering modem PIL also crashes the USB gadget (serial drops immediately), suggesting shared power domain interference.

**Investigation needed**: The modem crash with IPC_ROUTER enabled causes a system reboot (even with RELATED restart level). The `try_module_get` oops on corrupted `subsys->owner` (value=1) needs root-causing. Also check if `QCOM_BUS_SCALING` (currently disabled due to crash) is required for modem.

## WiFi (WCNSS) — Working

WCNSS PIL boots, authenticates, and brings up `wlan0` with full internet connectivity (IPv4 DHCP + IPv6 SLAAC). The prima/pronto WLAN driver (`drivers/staging/prima/wlan.ko`) loads as a module.

**Key issue fixed**: The rootfs had a stale `wlan.ko` from an earlier build that exported a duplicate `wcnss_get_iris_name` symbol (already exported by the built-in `wcnss_vreg.c`). The duplicate prevented module load. Updating the `.ko` on the rootfs fixed it.

## Kconfig Renames and Stale Symbols (3.18 → 4.4)

Additional renames discovered beyond the original table:

| 3.18 name | 4.4 name | Effect if wrong |
|-----------|----------|-----------------|
| `MSM_WATCHDOG_V2` | `QCOM_WATCHDOG_V2` | No HW watchdog — hard hangs freeze forever instead of rebooting |

## sysmon-qmi breaks subsys registration

`CONFIG_MSM_SYSMON_COMM` compiles both `sysmon.o` and `sysmon-qmi.o`. The QMI variant's `sysmon_notifier_register()` calls `qmi_svc_event_notifier_register()` which fails with `-ENODEV` on MSM8909 (no QMI SSCTL service). This error propagated up through `subsys_register()`, causing `device_unregister()` for modem and wcnss. Venus survived because `ssctl_instance_id=0` skips QMI registration.

**Fix**: Made `qmi_svc_event_notifier_register()` failure non-fatal in `sysmon-qmi.c` — log warning, return 0.

### Modem firmware location

Firmware files (`modem.mdt`, `mba.mbn`, `modem.b00-b24`, `wcnss.*`) are pre-extracted to `/lib/firmware/` on the Alpine rootfs (p36). The modem partition (mmcblk0p1, FAT16) has them in an `image/` subdirectory but we don't need to mount it.

## Boot Configuration

- eMMC rootfs on p36 (Alpine Linux / OpenRC) — no initramfs
- Cmdline: `root=/dev/mmcblk0p36 rootfstype=ext4 rootwait rw console=tty0 loglevel=7`
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
