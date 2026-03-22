# Modem Q6 Investigation — 3.18 → 4.4 Port

## Executive Summary

The modem Q6 DSP boots via PIL, MBA authenticates successfully, Q6 starts
running and creates basic SMD channels (IPCRTR, SSM_RTR), but stalls during
initialization — its internal watchdog fires after ~41s with
`dog.c:1522: Watchdog detects stalled initialization`.

**Key discovery (2026-03-22)**: The modem DOES boot and create SMD channels.
IPCRTR opens successfully on both sides. The modem registers 1 QMI service
(SSCTL, 0x2b). But it never creates APR channels (`apr_audio_svc`,
`apr_voice_svc`) or registers full QMI services (NAS, DMS, WDS, etc.).
Its watchdog fires because initialization never completes.

## Issues Found and Fixed

### 1. Missing `CONFIG_MSM_QDSP6_SSR` + `CONFIG_MSM_QDSP6_NOTIFIER` (FIXED)

**Root cause**: `SND_SOC_MSM8909` in Kconfig doesn't `select MSM_QDSP6_SSR`
or `MSM_QDSP6_NOTIFIER` (other machine drivers do). Without these,
`audio_notifier.c` and `audio_ssr.c` are not compiled. The header provides
a stub that returns `-ENODEV`:
```c
// include/linux/qdsp6v2/audio_notifier.h:92-96
static inline int audio_notifier_register(...) { return -ENODEV; }
```

**Result**: APR never registers for modem SSR notifications. Even when modem
goes ONLINE, APR never calls `apr_modem_up()` → stays in DOWN state forever.

**Fix**: Added `CONFIG_MSM_QDSP6_SSR=y` and `CONFIG_MSM_QDSP6_NOTIFIER=y`
to defconfig.

### 2. WCD codec `adsp_state_callback` crash (FIXED)

When `SUBSYS_AFTER_POWERUP` fires for modem, the audio notifier dispatches
to WCD codec's `adsp_state_callback`. This calls `msm8x16_wcd_device_up()`
→ `snd_soc_cache_sync()` → `regcache_sync()` with NULL regmap.

**Fix**: Added NULL guard for `registered_codec` in `adsp_state_callback()`,
and NULL check for `codec->component.regmap` in `msm8x16_wcd_device_up()`.

### 3. Subsystem fd lifecycle (`cat /dev/subsys_modem` exits) (FIXED)

`cat /dev/subsys_modem` opens the subsys device → `subsystem_get()` boots
modem → cat reads EOF → exits → fd closed → `subsystem_put()` → modem
immediately shuts down. Only ~50ms of uptime.

**Fix**: Use `sleep 999999 < /dev/subsys_modem &` to keep fd open. On a
production system, need a daemon or init script to hold the subsys fd.

### 4. Missing QMI/infrastructure configs (ADDED — needs testing)

Comparison of 3.18 vs 4.4 defconfig revealed major missing infrastructure:

| Config | 3.18 | 4.4 | Purpose |
|--------|------|-----|---------|
| `MSM_QMI_INTERFACE` | y | **missing** | QMI client/server framework |
| `QMI_ENCDEC` | y | **missing** | QMI encode/decode |
| `MEM_SHARE_QMI_SERVICE` | y | **missing** | Memory share for modem |
| `UIO_MSM_SHAREDMEM` | y | **missing** | Shared memory UIO |
| `MSM_SMD_PKT` | y | N/A (not in 4.4) | SMD packet channels |
| `DIAG_CHAR` | y | **missing** | Diagnostic channel |
| `MSM_BAM_DMUX` | y | N/A (not in 4.4) | BAM data mux |

**Added to defconfig**: `MSM_QMI_INTERFACE`, `QMI_ENCDEC`,
`MEM_SHARE_QMI_SERVICE`, `UIO` + `UIO_MSM_SHAREDMEM`.

**Status**: `MSM_QMI_INTERFACE` alone boots fine. `MEM_SHARE_QMI_SERVICE` +
`UIO_MSM_SHAREDMEM` cause EDL (boot failure). Need to debug probe crash
before re-enabling. QMI_ENCDEC is auto-selected by ARCH_MSM8909 — always on.

## Remaining Issues

### 5. APR transport timeout (OPEN)

After fixes #1 and #2, APR correctly detects modem ONLINE and tries to open
via `apr_tal_open()`. This waits for `dest_state` to be set by
`apr_smd_probe()`. But `apr_smd_probe()` fires when SMD discovers
"apr_audio_svc" platform device — which the modem Q6 never creates.

**Timeline**: `apr_tal:open timeout` at boot+6s, two retries at boot+11s.

### 6. Modem Q6 incomplete initialization (OPEN — root cause)

The Q6 firmware (same binary as 3.18) creates minimal channels and only
registers SSCTL QMI service. It never creates:
- APR channels (apr_audio_svc, apr_voice_svc)
- Full QMI services (NAS, DMS, WDS, VOICE, etc.)
- Watchdog fires at ~41s

**Evidence from experiments:**

| Measurement | Value |
|-------------|-------|
| PIL auth time | ~4s |
| err_ready | ~0.5s after auth |
| IPCRTR channel open | Yes, both sides |
| SSM_RTR_MODEM_APPS | Modem OPENING, APPS CLOSED |
| QMI services | Only SSCTL (0x2b) |
| APR channels | None |
| Modem crash time | ~60s with QMI_INTERFACE, ~41s without |
| USB survived crash | Yes (with RELATED restart, no Oops) |
| SMSM modem entry | 0x08000009 |

**Eliminated hypotheses:**
- ~~Missing QPIC clock~~: devm_clk_get returns error, 3.18 also has it NULL
- ~~DTS differences~~: modem DTS identical between 3.18 and 4.4
- ~~PIL boot sequence~~: identical code path
- ~~SMP2P/err_ready~~: working correctly
- ~~Missing QMI framework~~: MSM_QMI_INTERFACE now enabled, extends life
  from 41s → 60s but doesn't prevent stall

**ROOT CAUSE FOUND (2026-03-22): Missing `rmt_storage` daemon.**

Stock Android dmesg (`~/bq268-caf_msm-3.18/dmesg_stock.log`) reveals:
```
[6.380] init: starting service 'rmt_storage'...
[6.448] rmt_storage: Open Request for /boot/modem_fs1!
[6.449] rmt_storage: Open Request for /boot/modem_fs2!
[6.451] rmt_storage: Open Request for /boot/modem_fsg!
[6.452] rmt_storage: Open Request for /boot/modem_fsc!
[6.454] rmt_storage: Read iovec [offset=512, size=512] for /boot/modem_fs1!
[6.534] apr_tal:Modem Is Up                   ← modem completes init!
[13.57] sps:BAM 0x04044000 is registered.     ← A2 BAM comes up!
```

The modem Q6 needs its EFS (Embedded File System) served from eMMC
partitions. On Android, `rmt_storage` daemon reads/writes these via
QMI RFSA + UIO shared memory. Without it, modem EFS init task stalls
→ watchdog fires at ~55s.

**Modem EFS partitions on eMMC:**

| Partition | Block device | Size | rmt_storage name |
|-----------|-------------|------|-----------------|
| modemst1 | /dev/mmcblk0p26 | 1.5 MB | modem_fs1 |
| modemst2 | /dev/mmcblk0p27 | 1.5 MB | modem_fs2 |
| fsg | /dev/mmcblk0p3 | 1.5 MB | modem_fsg |
| fsc | /dev/mmcblk0p29 | 1 KB | modem_fsc |

**Kernel-side components (now enabled):**
- `UIO_MSM_SHAREDMEM` — creates `/dev/uio0` (rmtfs), `/dev/uio1` (rfsa_dsp), `/dev/uio2` (rfsa_mdm)
- `MEM_SHARE_QMI_SERVICE` — registers QMI RFSA service (0x1c), provides shared memory addresses to modem
- DTS nodes: `qcom,rmtfs_sharedmem@87c00000` (917 KB shared region)

**Known issue:** `hyp_assign_phys` fails with -5 (EIO) for the rmtfs
shared memory region at 0x87c00000. MSM8909 TZ may not support this
call. May need to remove or skip the hyp_assign — the 3.18 driver
(`sharedmem_qmi.c`) may not have had this call.

**What rmt_storage does (from Android binary strings):**
1. Opens `/dev/uio0` (rmtfs shared memory)
2. mmaps the shared memory region
3. Opens block devices via `/dev/block/bootdevice/by-name/modemst1` etc.
4. Modem writes storage requests to shared memory
5. rmt_storage reads the request, does block I/O, writes response back
6. modem reads response, continues init

**Stock Android binary:** `~/bq268-lineage/vendor/udotech/udosmart/proprietary/vendor/bin/rmt_storage`
(ARM ELF, dynamically linked against Android linker — can't run on Alpine directly)

**Open-source alternative:** postmarketOS/Linaro `rmtfs` project — designed
for non-Android Linux, works with UIO shared memory interface.

**Eliminated hypotheses (confirmed not the cause):**
- ~~SMEM version mismatch~~: confirmed 0x000B (same as 3.18)
- ~~SMD/SMSM code differences~~: functionally identical between 3.18 and 4.4
- ~~Modem firmware corruption~~: verified MD5 match with modem partition
- ~~Missing DIAG channels~~: modem stalls before creating any
- ~~Missing smd_pkt/smd_tty~~: modem stalls before creating data channels
- ~~A2 BAM init deadlock~~: modem stalls before A2 init (needs EFS first)
- ~~Modem DTS differences~~: identical between 3.18 and 4.4
- ~~USB_BAM~~: different BAM instance (0x78c4000), unrelated to A2 (0x4044000)

## Architecture: Expected Modem Boot Sequence (from stock dmesg)

```
AP (Linux)                              Q6 (Modem firmware)
───────────────────────────────────────────────────────
1. PIL boot: power, clocks, reset
   → pil_mss_reset()
   → pil_q6v5_reset() (core start)
                                        2. PBL runs, finds MBA
                                        3. MBA authenticates modem
   ← STATUS_AUTH_COMPLETE (0x4)
4. subsys goes ONLINE
5. SUBSYS_AFTER_POWERUP notification
6. sysmon-qmi connects to SSCTL
7. Proxy votes removed
                                        8. Q6 creates IPCRTR channel ✓
                                        9. Q6 registers SSCTL service ✓
                                        10. Q6 requests EFS via QMI RFSA ← BLOCKS HERE
11. rmt_storage reads modemst1/st2/fsg      (need rmt_storage daemon!)
   → serves read/write via /dev/uio0
                                        12. Q6 EFS init complete
                                        13. Q6 creates DIAG channels
                                        14. Q6 creates DATA/APR channels
                                        15. Q6 sets SMSM_A2_POWER_CONTROL
16. BAM_DMUX callback, BAM 0x4044000 init
17. apr_tal:Modem Is Up
                                        18. Q6 registers full QMI services
```

Steps 1-9 work on our kernel. Step 10 blocks because no rmt_storage daemon.
Steps 11-18 are what should happen once rmt_storage is running (based on stock dmesg).

## Files Reference

| Component | File | Key Lines |
|-----------|------|-----------|
| PIL MSS driver | `drivers/soc/qcom/pil-q6v5-mss.c` | probe: 202-450 |
| PIL MSA (auth) | `drivers/soc/qcom/pil-msa.c` | auth: 837-897 |
| PIL Q6v5 (reset) | `drivers/soc/qcom/pil-q6v5.c` | proxy votes: 86-192 |
| Subsystem restart | `drivers/soc/qcom/subsystem_restart.c` | subsys_start: 669-712 |
| APR transport | `drivers/soc/qcom/qdsp6v2/apr_tal.c` | open: 158-221, probe: 239-263 |
| Audio notifier | `drivers/soc/qcom/qdsp6v2/audio_notifier.c` | reg: 542-584 |
| Audio SSR | `drivers/soc/qcom/qdsp6v2/audio_ssr.c` | register: 26-37 |
| WCD codec | `sound/soc/codecs/msm8x16-wcd.c` | callback: 5591-5627 |
| QMI interface | `drivers/soc/qcom/qmi_interface.c` | enabled |
| Shared memory UIO | `drivers/uio/msm_sharedmem/msm_sharedmem.c` | creates /dev/uio0-2 |
| Shared memory QMI | `drivers/uio/msm_sharedmem/sharedmem_qmi.c` | RFSA QMI service |
| RFSA protocol | `drivers/uio/msm_sharedmem/remote_filesystem_access_v01.h` | QMI message defs |
| BAM DMUX | `drivers/soc/qcom/bam_dmux.c` | ported from 3.18 |
| SMD packet | `drivers/char/msm_smd_pkt.c` | ported from 3.18 |
| DIAG char | `drivers/char/diag/diagchar_core.c` | late_initcall fix |
| Modem DTS | `arch/arm/boot/dts/qcom/msm8909.dtsi` | MSS: 2048-2089 |
| rmtfs DTS | `arch/arm/boot/dts/qcom/msm8909.dtsi` | rmtfs_sharedmem@87c00000 |
| Stock dmesg | `~/bq268-caf_msm-3.18/dmesg_stock.log` | reference for working modem |
| Stock rmt_storage | `~/bq268-lineage/vendor/.../vendor/bin/rmt_storage` | Android binary (ARM) |
