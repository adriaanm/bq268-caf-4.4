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

After successful PIL boot + auth, the modem Q6 starts running. It creates IPCRTR SMD channel (opens both sides) and registers SSCTL QMI service (0x2b). But it never creates APR audio channels (`apr_audio_svc`, `apr_voice_svc`) or full QMI services (NAS, DMS, WDS). Its internal watchdog fires after ~55s: `dog.c:1522:Watchdog detects stalled initialization`.

**Fixes applied (2026-03-22):**
- `CONFIG_MSM_QDSP6_SSR` + `CONFIG_MSM_QDSP6_NOTIFIER`: `SND_SOC_MSM8909` didn't select these (other machine drivers do). Without them, `audio_notifier_register()` was a `-ENODEV` stub. APR never learned modem was online.
- `CONFIG_MSM_QMI_INTERFACE`: Provides kernel QMI framework. Extends modem life from 41s→55s (sysmon-qmi connects to modem's SSCTL service).
- WCD codec crash guard: `adsp_state_callback` calls `regcache_sync(NULL)` — codec uses old `.read`/`.write` callbacks, not regmap. Guarded with NULL check.
- Subsystem fd lifecycle: `cat /dev/subsys_modem` exits immediately → modem shuts down. Use `sleep 999999 < /dev/subsys_modem &` to hold fd.
- BAM DMUX: Ported from 3.18. Probes, registers SMSM callbacks. Modem never reaches A2_POWER_CONTROL stage.
- MEM_SHARE_QMI_SERVICE: Fixed EDL crash by removing `qcom,allocate-boot-time` from DTS (caused early `hyp_assign_phys()` before SCM init). Probes and registers QMI service 0x34.

**Eliminated hypotheses:** QPIC clock (was NULL in 3.18 too), DTS differences (identical), PIL boot sequence (identical), BAM DMUX (probed, modem doesn't reach handshake), MEM_SHARE (probed, no effect).

**Remaining:** Modem stalls very early — after IPCRTR/SSCTL but before any data/audio/QMI services. Need modem-side logs to identify which init task stalls. See `MODEM-INVESTIGATION.md` for full details.

**ROOT CAUSE FOUND & FIXED (2026-03-22):** Modem needs `rmt_storage` userspace daemon to serve EFS partition I/O (modemst1, modemst2, fsg, fsc). Without it, modem EFS init task stalls → watchdog fires. Custom daemon at `~/bq268-alpine/tools/rmt_storage.c`. Bug found during testing: QMI RMTFS `phys_offset` in RW_IOVEC is buffer-relative (e.g. 0x200), not an absolute physical address — must add `shmem.phys_addr` base (0x87c00000). With fix, modem fully initializes: APR audio OPENED, all DIAG channels OPENED, DATA1-4/DS channels created, EFS reads+writes served, no watchdog crash.

**Further investigation (2026-03-22):**
- SMEM version confirmed 0x000B (no communication partitions) — not a layout mismatch
- Modem DTS identical between 3.18 and 4.4 — not a DTS issue
- Modem firmware on rootfs verified identical to modem partition — not corruption
- SMD core code (msm_smd.c) functionally identical between 3.18 and 4.4
- DIAG_CHAR enabled (module) — modem never creates DIAG SMD channels (stalls before that)
- MSM_SMD_PKT ported from 3.18 — creates /dev/smdpkt* devices but modem never creates those channels either
- SMSM masks show BAM_DMUX correctly registered for A2_POWER_CONTROL — modem never sets this bit
- 3.18 kernel modem test inconclusive: device hard-locked when modem was booted on 3.18+Alpine
- Modem firmware strings show A2 task waits for "apps action" — possible chicken-and-egg with BAM init

**Observed modem boot timeline (empirical):**
```
t+0s    PIL boot starts (proxy votes, firmware load)
t+4s    MBA auth complete (STATUS_AUTH_COMPLETE=4)
t+5s    err_ready SMP2P received, subsys ONLINE
t+5s    APR tries apr_tal_open → times out after 5s (no apr_audio_svc channel)
t+10s   Second apr_tal_open timeout
t+15s   IPCRTR channel OPENED both sides, SSCTL service (0x2b) registered
        (only 1 QMI service, no NAS/DMS/WDS/VOICE)
t+55s   dog.c:1522 watchdog fires, SSR RELATED restart triggered
```

**Modem boot timeline WITH rmt_storage (2026-03-22):**
```
t+0s    PIL boot starts
t+3.5s  MBA auth complete
t+4s    err_ready, subsys ONLINE, sysmon-qmi connected
t+4s    apr_tal:Modem Is Up — APR audio channel OPENED
t+4s    rmt_storage: 4x OPEN (modem_fs1, fs2, fsg, fsc), ALLOC_BUFF, reads
t+5s    rmt_storage: full modem_fs2 read (1790 sectors), modem_fs1 write (1792 sectors)
t+∞     Stable — no watchdog, DIAG channels OPENED, DATA1-4/DS OPENING (modem side)
```

**SMSM state (with rmt_storage):**
- APPS (entry 0): `0x00001429` = SMSM_INIT | SMSM_SMDINIT | SMSM_RPCINIT | SMSM_TIMEWAIT | SMSM_PROC_AWAKE
- Modem (entry 1): `0x08000009` = SMSM_INIT | SMSM_SMDINIT | bit27
- Neither side sets SMSM_A2_POWER_CONTROL (bit 1) — BAM DMUX handshake still not triggered
- Modem opens DATA1-4/DATA11/DS channels (OPENING state) but AP BAM DMUX doesn't respond

**Configs needed on 3.18 but missing/broken on 4.4:**

| Config | Status | Notes |
|--------|--------|-------|
| `MSM_QDSP6_SSR` | Fixed | Stub returned -ENODEV without it |
| `MSM_QDSP6_NOTIFIER` | Fixed | Required by SSR for audio notification |
| `MSM_QMI_INTERFACE` | Fixed | Extends modem life 41→55s |
| `MSM_BAM_DMUX` | Ported from 3.18 | Source missing from 4.4 tree entirely |
| `MEM_SHARE_QMI_SERVICE` | Fixed | DTS `allocate-boot-time` caused EDL |
| `DIAG_CHAR` | Fixed | Built-in with `late_initcall` (EDL with `module_init`) |
| `UIO_MSM_SHAREDMEM` | Fixed | Creates /dev/uio0 (rmtfs). hyp_assign_phys fails (-5) but non-fatal. |
| `SERIAL_MSM_SMD` | Already enabled | Creates /dev/smd* TTY devices; modem never creates data channels |
| `MSM_SMD_PKT` | Ported from 3.18 | Source missing from 4.4 tree; creates /dev/smdpkt* devices |
| `USB_CONFIGFS_F_DIAG` | Fixed | USB DIAG function for DIAG_CHAR over USB |
| `UIO` + `UIO_MSM_SHAREDMEM` | Fixed | Creates /dev/uio0 (rmtfs), /dev/uio1-2 (rfsa). hyp_assign_phys fails (-5) but is non-fatal. |
| `RMNET_DATA` | Added | MAP protocol network driver over BAM DMUX. Was `=y` on 3.18. |
| `USB_BAM` | Added | SPS peripheral-to-peripheral DMA for USB ↔ modem. Depends on SPS + USB_GADGET. |
| `MSM_RMNET_BAM` | N/A | Existed in 3.18 but removed in 4.4. Replaced by `MSM_BAM_DMUX` + `RMNET_DATA`. |
| `USB_CONFIGFS_RMNET_BAM` | Blocked | 4.4 USB RMNET gadget depends on `IPA` (Internet Packet Accelerator) — too heavyweight for MSM8909. |

**CAF 4.4 stub pattern trap:** Many subsystem headers (`audio_notifier.h`, `smsm.h`, etc.) have `#ifdef CONFIG_XXX` with real implementation and `#else` with inline stubs returning `-ENODEV`. When a config is missing, the code compiles and links fine but does nothing. Always check the header for stub patterns when a subsystem fails silently.

**DIAG_CHAR `module_init` causes EDL:** `CONFIG_DIAG_CHAR=y` with stock `module_init(diagchar_init)` causes EDL (hard crash into Emergency Download Mode). The crash is a PMIC reset, not a normal kernel panic — `panic=5` doesn't trigger reboot. Root cause: init ordering issue — diagchar_init at `device_initcall` level runs before USB subsystem or another dependency is fully ready. **Fix**: Change to `late_initcall(diagchar_init)`. As a module (=m), it works fine since loading happens after boot.

**smd_pkt missing from CAF 4.4:** Like bam_dmux, `msm_smd_pkt.c` is absent from the CAF 4.4 tree — DTS nodes exist (`qcom,smdpkt`) but no driver. Copied from 3.18, compiled without changes. Creates `/dev/smdpkt*` and `/dev/smdcntl*` char devices for userspace QMI tools.

**BAM DMUX missing from CAF 4.4:** The `bam_dmux.c` source file does not exist in the CAF 4.4 tree at all — not disabled, not renamed, just absent. The DTS node `qcom,bam_dmux@4044000` still exists (orphaned). CAF apparently dropped it, perhaps expecting newer data path (IPA or mainline `qcom_bam_dmux` from 5.17+). Had to copy all 3 files from 3.18 — compiled without changes.

**`qcom,allocate-boot-time` DTS trap:** The memshare DTS node has `qcom,allocate-boot-time` which calls `hyp_assign_phys()` (SCM hypervisor call) during `platform_device_add()`. On MSM8909, SCM may not be ready this early → kernel panic before console → EDL. Removing the property defers allocation to QMI runtime request. The modem can still request shared memory dynamically.

**BAM DMUX vs SMD DATA channels — completely separate subsystems:** BAM DMUX uses SPS/BAM DMA pipes at 0x4044000. SMD DATA channels (DATA1-4, DATA11, DS visible in `/sys/kernel/debug/smd/ch`) are shared-memory ring buffers used for AT commands, QMI control, PPP. They are unrelated to BAM DMUX. The modem opening DATA1-4 in SMD has nothing to do with BAM DMUX data path. BAM DMUX does not call `smd_named_open_on_edge()` anywhere.

**BAM DMUX vs QMI control — also independent:** `qmuxd` opens QMI control channels (`DATA5_CNTL` via `/dev/smdcntl0`) but does NOT trigger A2_POWER_CONTROL. postmarketOS gets BAM DMUX working on MSM8916 without qmuxd, dpmQmiMgr, or netmgrd. The `memshare hyp_assign_phys` failure is also NOT the cause — stock 3.18 has the same failure and BAM works fine.

**`msm_rmnet_bam.c` removed from CAF 4.4:** On 3.18, `drivers/net/ethernet/msm/msm_rmnet_bam.c` consumed `bam_dmux_ch_N` platform devices (added by `handle_bam_mux_cmd_open()` in bam_dmux.c) and created `rmnet0`-`rmnet7` network interfaces. This driver is completely absent from CAF 4.4. The 4.4 tree only has `u_bam.c` (USB gadget BAM) as a BAM DMUX consumer, which requires the Android USB rmnet gadget. Must port `msm_rmnet_bam.c` from 3.18 for Alpine.

**Mainline BAM DMUX (Linux 5.17+, Stephan Gerhold):** Clean rewrite as `drivers/net/wwan/qcom_bam_dmux.c`. Uses `qcom_smem_state` + IRQs instead of SMSM callbacks. Creates `wwan%d` interfaces directly from BAM DMUX CMD_OPEN commands — no intermediate platform devices. The modem sets power control autonomously after its internal init.

**SMSM A2_POWER_CONTROL — modem A2 task alive but not activating:** Modem never sets bit 1 of SMSM_MODEM_STATE despite full init (APR up, DIAG up, EFS served). BAM DMUX SMSM callbacks confirmed registered. All stock Android daemons (qmuxd, dpmQmiMgr, netmgrd, irsc_util) confirmed unnecessary by postmarketOS. Forcing BAM init from AP side via debugfs (`echo 1 > /sys/kernel/debug/bam_dmux/force_a2pc`) successfully registers BAM 0x04044000 (6 pipes, ver 0x25) but immediately crashes the modem: `a2_power.c:2783:A2 Assertion Failed`. This confirms: (1) BAM hardware works, (2) modem A2 task is alive and monitoring BAM state, (3) A2 deliberately does not set A2_POWER_CONTROL — some internal precondition is unmet. APPS SMSM state matches stock (`0x00001429`). Needs modem-side DIAG logging to identify what A2 is waiting for.

**IPC Router Security (`CONFIG_IPC_ROUTER_SECURITY`) must be disabled:** On stock Android, `irsc_util` runs at boot with `/vendor/etc/sec_config` and calls `IPC_ROUTER_IOCTL_CONFIG_SEC_RULES` to configure security policies, then signals `irsc_completion`. Without this, `wait_for_irsc_completion()` in `ipc_router_socket.c:347` blocks **forever** (30s timeout loop, infinite retry) on any `sendto()` from a CLIENT_PORT. This would block all userspace QMI clients (qmicli, ModemManager, libqmi). We don't have `irsc_util` or `sec_config` for Alpine, so disable the config entirely — makes the wait a no-op.

**Modem userspace architecture (postmarketOS equivalent):**
- `rmt_storage` — serves modem EFS partitions (custom, in `~/bq268-alpine`)
- `libqmi` / `qmi-utils` — QMI client tools (Alpine `community` repo). On CAF 4.4 with AF_MSM_IPC (not qrtr), needs `libqipcrtr4msmipc` adapter or `libsmdpkt_wrapper`.
- `ModemManager` — high-level modem management daemon (uses libqmi)
- `smdcntl0` → SMD channel `DATA5_CNTL` (primary QMI control)
- `smdcntl8` → SMD channel `DATA40_CNTL` (secondary QMI control)

**Subsystem fd lifecycle:** Opening `/dev/subsys_modem` calls `subsystem_get()` which boots the modem. When the fd closes, `subsystem_put()` shuts it down. On Android, rild holds the fd permanently. On Alpine, use: `sleep 999999 < /dev/subsys_modem &`. If the holder process dies (e.g., modem SSR crashes it), the modem shuts down.

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
- msm8x16-wcd.c: NULL guard in `adsp_state_callback` and `msm8x16_wcd_device_up` for missing regmap
- bam_dmux.c: ported from 3.18 (not in CAF 4.4 tree)
- memshare DTS: removed `qcom,allocate-boot-time` (crashes early boot via `hyp_assign_phys`)
