# Spontaneous Hard Crash Investigation — 2026-04-01

## Symptom

Device spontaneously reboots during interactive use of wata (multi-threaded
Matrix fbclient). PMIC reports Hard Reset (cold boot) + PS_HOLD power-off
reason. Crash bypasses the kernel entirely — no watchdog bark, no panic, no
ramoops data. Instant SoC death.

Previously seen on 6.19 mainline kernel under heavy DDR write traffic, where
crashes were consistent and reproducible.

## What was ruled out

| Hypothesis | Test | Result |
|---|---|---|
| Modem (Q6) | Disabled rmt-storage + modem services | Still crashes |
| WiFi throughput | 200MB bulk transfer, 20× bidirectional 20MB | No crash |
| HTTP/TLS | 50 HTTP + 20 HTTPS rapid requests | No crash |
| Display (fbtft) | 1000 full-screen framebuffer writes | No crash |
| Combined net+display | 500 rounds framebuffer write + HTTP | No crash |
| Key presses | Physical keys pressed during all synthetic tests | No crash |
| CPU frequency | Capped to 200MHz, 2 CPUs only | Still crashes |
| Kernel panic path | sysrq-c test | Works correctly (warm reset, pstore data) |

## What triggers it

Only wata — a multi-threaded application simultaneously doing:
- Key input processing (GPIO interrupts)
- Matrix HTTP long-poll sync (WiFi/WCNSS DXE DMA)
- Framebuffer rendering (CPU writes → SPI BAM DMA to display)

No single subsystem in isolation reproduces it. The combination under wata's
specific threading/timing pattern is required.

## Why pstore can't capture it

The PMIC always does a **cold** reset for this crash — DDR power is cut, all
RAM contents lost. This happens despite configuring the PMIC for warm reset at
probe time (`qpnp_pon_system_pwr_off(PON_POWER_OFF_WARM_RESET)` in
qpnp-power-on probe, confirmed rc=0, type=0x01).

Kernel-initiated panics (sysrq-c) correctly produce warm resets with preserved
pstore data. The spontaneous crash kills the SoC more violently — likely a
power rail collapse or TZ-forced cold reset that overrides the warm reset
configuration.

## Debugging infrastructure built

All confirmed working (tested with sysrq-c panic):

1. **Watchdog bark → panic()** — `drivers/soc/qcom/watchdog_v2.c`: bark handler
   calls `panic()` instead of immediate hardware bite, giving ramoops time to
   write. `panic_wdog_handler` re-arms with 15s failsafe.

2. **PMIC warm reset at boot** — `drivers/input/misc/qpnp-power-on.c`: probe
   calls `qpnp_pon_system_pwr_off(PON_POWER_OFF_WARM_RESET)` so unexpected
   PS_HOLD drops preserve DDR.

3. **download_mode=0** — `drivers/power/reset/msm-poweroff.c`: prevents TZ
   from routing to fastboot/EDL on abnormal reset.

4. **IMEM restart_reason cleared** — `msm-poweroff.c` probe: writes 0x0 to
   prevent stale bootloader magic causing fastboot entry.

5. **Panic forces warm reset** — `msm_restart_prepare()`: `in_panic` always
   sets `need_warm_reset = true` regardless of dload_mode.

6. **ramoops at 0x8f500000** — moved from 0x9ff00000 (which aboot fills with
   0xFF on every boot). New address is between peripheral and venus_qseecom
   carveouts, in a region aboot does not reinitialize on warm boot.

7. **dload_type IMEM node** — `arch/arm/boot/dts/qcom/msm8909.dtsi`: added
   `dload_type@18` (matches MSM8996+), enables `/sys/kernel/dload` sysfs.

8. **pstore mount** — added `pstore /sys/fs/pstore pstore defaults 0 0` to
   `/etc/fstab` on the Alpine rootfs.

## Commits

- `b687b4c` crash debug: preserve ramoops across watchdog reset
- `ab3ce68` crash debug: default PMIC to warm reset, disable dload mode
- `e3482ac` dts: bq268: move ramoops to 0x8f500000 (aboot-safe region)

## Hypotheses for root cause

1. **SPI BAM DMA + WCNSS DXE bus contention** — both are bus masters doing DMA
   to/from DDR. Under wata's concurrent load, they may cause BIMC stalls or XPU
   violations. QCOM_BUS_SCALING is disabled (crashes at boot on 4.4), so there
   is no DDR bandwidth arbitration.

2. **TZ XPU violation** — WCNSS DXE writes to a protected memory region under
   specific buffer allocation patterns, triggering TZ to force a cold reset.

3. **VDD_MEM brownout** — concurrent DMA from multiple bus masters causes peak
   current draw on the DDR power rail, drooping below minimum voltage.

## Next steps to try

- **Disable display during wata** — unload fbtft, run wata over SSH with no
  framebuffer rendering. If crash stops, SPI BAM DMA is the co-trigger.
- **Investigate QCOM_BUS_SCALING boot crash** — if bus scaling can be fixed,
  DDR QoS arbitration might prevent the contention.
- **Check WCNSS SMMU/XPU configuration** — compare 3.18 vs 4.4 IOMMU setup
  for the Pronto subsystem.
- **Try `CONFIG_QCOM_FORCE_WDOG_BITE_ON_PANIC`** — if there's a TZ abort, the
  watchdog debug registers might capture it (but this is speculative).
