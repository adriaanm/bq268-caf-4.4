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

## 2026-04-03 Update: Fbcon scrolling alone can crash

New observation: simply scrolling through dmesg logs on fbcon (no wata, no WiFi)
is enough to crash and reboot. This narrows the trigger from "multi-subsystem
concurrency under wata" to "rapid framebuffer writes via fbcon".

### Display data path (fbtft over SPI BAM DMA)

The display is a 160×128 ST7735S SPI panel driven by `fb_st7735r` (fbtft staging
driver), NOT the MDSS/MDP3 stack. The MDSS SPI panel driver is disabled in DTS.

```
fb0: fb_st7735r frame buffer, 160x128, 40 KiB video memory, 16 KiB DMA buffer memory, fps=33, spi5.0 at 16 MHz
```

Data flow during fbcon output:

1. **fbcon** writes characters to `screen_buffer` (40 KiB, `vzalloc`'d) via
   `sys_imageblit`/`sys_copyarea`/`sys_fillrect`.
2. Each write calls `fbtft_mkdirty()` → `schedule_delayed_work(HZ/33 ≈ 30ms)`.
3. Deferred work: `fbtft_write_vmem16_bus8()` copies dirty region from vmem →
   txbuf (16 KiB DMA coherent, byte-swapping `cpu_to_be16`), then calls
   `fbtft_write_spi()` → `spi_sync()`.
4. Full screen = 40960 bytes / 16384 bytes txbuf = **3 SPI messages** per update.
5. SPI controller: CAF `spi_qsd.c` (BLSP1 QUP5 at 0x78b9000) using **BAM DMA**
   (consumer pipe 12, producer pipe 13, BLSP1 BAM at 0x7884000).
6. At 16 MHz SPI clock, each 16 KiB chunk takes ~8ms. Full update ≈ 20ms.

Under rapid console output (e.g. `dmesg`), deferred_io fires every 30ms. The SPI
bus is active ~66% of the time (20ms transfer / 30ms interval).

### Analysis: `spi_qsd.c` ignores `is_dma_mapped` (fixed)

**The bug:** fbtft allocates txbuf via `dmam_alloc_coherent()` and sets
`spi_message.is_dma_mapped = 1` with a valid `tx_dma` address. The CAF
`spi_qsd.c` driver ignores this flag and unconditionally calls
`dma_map_single()` on the buffer in `msm_spi_bam_map_buffers()`, overwriting the
pre-set `tx_dma`.

**On this platform, the double-mapping is coincidentally harmless.** The txbuf
allocation path with `GFP_DMA`:

```
dmam_alloc_coherent(dev, 16KiB, &dma, GFP_DMA)
→ __dma_alloc()
→ !gfpflags_allow_blocking(GFP_DMA)  [GFP_DMA has no __GFP_DIRECT_RECLAIM]
→ __alloc_from_pool()                 [atomic DMA pool]
→ gen_pool_alloc(atomic_pool, ...)
```

The atomic pool was initialized via `__alloc_from_contiguous()` from CMA. On
MSM8909 (non-highmem, all lowmem), CMA returns `page_address(page)` — a
**linear-map address**. The gen_pool's virtual addresses are linear-map. So
`virt_to_page()` in `dma_map_single()` returns the correct page, and the
overwritten `tx_dma` happens to equal the original. BAM DMA reads from the
correct physical address.

**Fix applied:** `spi_qsd.c` now checks `spi_message.is_dma_mapped` (propagated
via `dd->is_dma_mapped`) and skips `dma_map_single()`/`dma_unmap_single()` when
the caller already provided DMA addresses. This:
- Eliminates ~100 unnecessary DMA map/unmap ops per second (cache clean on
  non-cacheable coherent memory — harmless but wasteful).
- Is the correct behavior per the SPI framework contract.
- Prevents bugs on platforms where the coherent buffer IS in vmalloc range
  (highmem systems), where `virt_to_page()` would return a wrong page and
  `dma_map_single()` would produce a garbage DMA address.

Changed files:
- `drivers/spi/spi_qsd.h` — added `is_dma_mapped` field to `struct msm_spi`
- `drivers/spi/spi_qsd.c` — `msm_spi_transfer_one()` captures flag from
  `master->cur_msg->is_dma_mapped`; `msm_spi_bam_map_buffers()` and
  `msm_spi_bam_unmap_buffers()` skip when flag is set.

### Why this fix alone may not resolve the crash

On MSM8909, the double-mapping produces correct DMA addresses. The unnecessary
cache ops are for `DMA_TO_DEVICE` on non-cacheable pages — ARM's `dc cvac` on
strongly-ordered memory is architecturally a NOP. So the practical effect of the
fix is small on this platform.

The crash symptom (instant reboot, PMIC Hard Reset, no panic/watchdog bark)
indicates something below the kernel — likely a **NOC/BIMC bus error**, **XPU
violation**, or **VDD_MEM brownout** from sustained DMA activity.

### fbtft-side fixes (likely higher impact than spi_qsd fix)

Three changes inspired by how mainline DRM tiny drivers handle SPI displays:

**A. Fix `fb_write` dirty tracking (most likely wata crash cause)**

`fbtft_fb_write()` had a `/* TODO */` that marked the ENTIRE screen dirty on
every `/dev/fb0` write, regardless of how many bytes were actually written. wata
writes directly to `/dev/fb0`, so every small write triggered a full 40960-byte
SPI DMA transfer. If wata writes frequently (e.g., updating a single text line),
this creates massive unnecessary SPI bus load.

Fixed: compute actual dirty lines from `*ppos` and `res` (bytes written).
A 320-byte write (one line) now transfers ~320 bytes over SPI instead of 40960.

Note: fbcon's `fillrect`/`copyarea`/`imageblit` already tracked dirty lines
correctly. This bug only affected the `/dev/fb0` write path.

**B. Increase txbuflen to full frame (40960 bytes)**

With txbuflen=16384, a full-screen update required 3 separate `spi_sync()` calls,
each doing: pm_runtime get → QUP reset → BAM setup → DMA → BAM teardown → QUP
reset → pm_runtime put. Three BAM DMA setup/teardown cycles per frame.

With txbuflen=40960, the entire frame fits in one SPI transfer. One BAM cycle per
frame. Reduces per-frame overhead by ~67% and eliminates rapid QUP state
transitions that could hit silicon errata.

The SPI BAM max transfer is 64 KiB (`SPI_MAX_TRFR_BTWN_RESETS = 65520`), so
40960 fits in a single BAM descriptor chain. The DMA coherent pool can handle
this — the atomic pool is typically 256 KiB.

DTS change: `txbuflen = <40960>` (was 16384).

**C. Display update backpressure**

Added `update_in_progress` flag. When `fbtft_update_display()` is running (SPI
transfer in progress), `fbtft_mkdirty()` accumulates dirty lines but skips
`schedule_delayed_work()`. When the transfer completes, if dirty lines
accumulated, it re-schedules the work.

This prevents queueing new SPI transactions while one is in flight. Without this,
rapid writes could build up a queue of deferred work invocations, each triggering
a full SPI transfer cycle. With backpressure, dirty writes coalesce naturally —
multiple writes during one SPI transfer merge into a single update.

Mainline DRM achieves the same via atomic commit serialization — a new commit
waits for the previous one to complete. Our approach is lighter-weight but
achieves the same goal.

### Remaining hypotheses

1. **Bus contention without QoS.** `CONFIG_QCOM_BUS_SCALING` disabled (hangs at
   boot). No BIMC bandwidth voting. Under sustained DMA, concurrent bus masters
   could cause BIMC timeouts → NOC error → SoC reset.

2. **BAM hardware bug** — rapid pipe resubmission causing internal state
   corruption. Mitigated by txbuflen increase (fewer resubmissions) and
   backpressure (fewer updates per second).

3. **VDD_MEM brownout** — sustained DMA could cause peak current issues.
   Mitigated by backpressure reducing DMA duty cycle.

4. **`spi_qsd.c` ignores `is_dma_mapped`** — **Fixed**. Correctness bug,
   coincidentally harmless on MSM8909.

### What mainline does differently

The mainline DRM tiny driver (`drivers/gpu/drm/tiny/st7735r.c`) and `mipi-dbi`
helper layer differ from fbtft in several ways:

- **Damage tracking**: DRM uses `drm_atomic_helper_damage_merged()` to compute a
  single bounding rectangle of changed pixels. Only the changed region is sent.
- **No pre-mapped DMA**: mipi-dbi uses `spi_sync()` with plain kernel buffers,
  letting the SPI controller driver handle DMA mapping. No `is_dma_mapped` flag.
- **Implicit backpressure**: atomic commits serialize — a new update blocks until
  the previous SPI transfer completes. No runaway queue buildup.
- **No deferred I/O for DRM**: updates are triggered by atomic commits, not page
  fault / timer polling. More efficient for applications that know when they're
  done drawing.

The MDSS SPI panel driver does NOT exist in this CAF 4.4 kernel. MDP3 only
supports DSI and LCDC output interfaces — there is no MDP3 SPI output path.

## Test plan (when device is available)

### Step 1: Verify all fixes compile and boot

```sh
just bootimg && just boot   # RAM-boot first
just serial 'dmesg | grep fb_st7735r'   # check txbuf size changed
```

Expected: `40 KiB video memory, 40 KiB DMA buffer memory` (was 16 KiB DMA).

### Step 2: Test wata

Run wata normally. The combination of:
- Precise dirty tracking (no more full-screen DMA for small writes)
- Single SPI transfer per frame (no rapid BAM resubmission)
- Backpressure (coalesces writes during SPI transfer)

should dramatically reduce SPI bus load during wata's framebuffer rendering.

### Step 3: Stress test fbcon

```sh
just serial 'dmesg; dmesg; dmesg'   # rapid console output
just serial 'for i in $(seq 1000); do echo "line $i"; done'
```

### Step 4: If crash persists — diagnostic steps

**Check pstore:**
```sh
just serial 'ls -la /sys/fs/pstore/'
just serial 'cat /sys/fs/pstore/console-ramoops-0'
```

**Reduce update rate:**
Change DTS `fps = <10>` (was 30) to increase deferred_io delay from 33ms to
100ms, further reducing SPI bus utilization.

**Disable display:**
```sh
just serial 'echo 1 > /sys/class/graphics/fb0/blank'
```
Then test wata over SSH with no display. If stable, display is confirmed trigger.

**Investigate bus scaling:**
`CONFIG_QCOM_BUS_SCALING` crashes at boot — fixing this would enable DDR QoS
arbitration. This is the deeper fix but requires DTS/driver debug.

## Changed files summary

| File | Change |
|------|--------|
| `drivers/spi/spi_qsd.c` | Respect `is_dma_mapped` flag |
| `drivers/spi/spi_qsd.h` | Add `is_dma_mapped` field |
| `drivers/staging/fbtft/fbtft-core.c` | Fix `fb_write` dirty tracking; add backpressure |
| `drivers/staging/fbtft/fbtft.h` | Add `update_in_progress` field |
| `arch/arm/boot/dts/qcom/msm8909-bq268.dts` | txbuflen 16384→40960 |
