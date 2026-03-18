# BQ268 Kernel — CAF 4.4 Branch

## Reproducibility

Every repeated command must be tracked in git as a self-describing recipe. The `justfile` is the single entry point for all build, flash, and analysis steps. If you find yourself running a command more than once, add it as a `just` recipe.

Run `just` to list all available recipes.

## Workflow: Commit Before Flash

Every kernel change that will be flashed MUST follow this discipline:

1. **Commit first** — create a git commit with the changes before building/flashing
2. **Build and flash** — `just bootimg`, then `just boot`
3. **Record outcome** — amend the commit message with the boot test result:
   - `BOOT TEST: PASS` — device boots successfully
   - `BOOT TEST: FAIL (description)` — device did not boot, with brief failure description
   - `BOOT TEST: PARTIAL (description)` — boots but with issues
4. **Record experiment** — `just note "PASS: description"` (records on HEAD)

## Tasks & Experiments — ALWAYS use `just` recipes

- **`just tasks`** — show current tasks
- **`just task-add "description"`** — add a new task
- **`just task-start "pattern"`** — mark a task in-progress
- **`just task-done "pattern"`** — mark a task done
- **`just experiments`** — show experiment log
- **`just note "message"`** — record an experiment outcome on HEAD

## Current State (2026-03-18)

Kernel version: **4.4.21-bq268**
Base: CAF LA.UM.5.7.c25 (MSM8916 branch) + MSM8909 support ported from 3.18
Toolchain: **GCC 7.4.1** (Linaro 2019.02) at `/opt/toolchains/gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf/`
Rootfs: Alpine 3.21.3 on userdata (p36), OpenRC (same as 3.18)
Reference repo: `~/bq268-caf_msm-3.18` (working 3.18 kernel with all hardware)

### Working (builds, untested on device)
- **Clocks**: clock-gcc-8909.c, clock-rpm-8909.c, clock-a7.c (legacy COMMON_CLK_MSM)
- **Pinctrl**: pinctrl-msm8909.c
- **Board**: board-8909.c (DT-based SMP via KPSS ACC v2)
- **DTS**: Full msm8909.dtsi + 37 supporting dtsi, msm8909-bq268.dts
- **SMP**: ACC/SAW2 nodes at 0xb088000+, enable-method=qcom,kpss-acc-v2
- **USB**: qcom,usb-otg-snps compatible, USB_CHIPIDEA + USB_CONFIGFS_ACM/ECM
- **Display**: fbtft ST7735S with BQ268 init sequence, backlight in par->bl_dev
- **PIL/SSR**: sysmon.o + sysmon-qmi.o wired for MSM_SYSMON_COMM (SMD-based)
- **APR**: SUBSYS_UP→SUBSYS_LOADED in apr_v3.c (no-LPASS MSM8909 fix)
- **WiFi**: prima wlan.ko builds as module (drivers/staging/prima/)
- **WCNSS**: WCNSS_CORE built-in, regulator_set_load fix in wcnss_vreg.c

### Not yet working (parked)
- **Audio**: WCD codec + machine driver copied but not compiling (API changes)
  - Files at: sound/soc/codecs/msm8x16-wcd.c, sound/soc/msm/msm8952.c
  - Done: w->codec→snd_soc_dapm_to_codec, spmi->usid, cache removal
  - TODO: spmi_get_resource, reg_cache_size, MBHC callbacks, audio_notifier
- **Modem**: PIL enabled, DTS nodes present, untested

### Key Architecture Decisions

| Decision | Rationale |
|----------|-----------|
| **COMMON_CLK_MSM only** | Legacy CAF clock framework. Mainline COMMON_CLK conflicts (duplicate clk_enable etc.) |
| **USB configfs** | 4.4 removed USB_G_ANDROID. Alpine's usb-gadget init handles configfs |
| **DTS USB compatible** | `qcom,usb-otg-snps` (4.4 phy-msm-usb.c), was `qcom,hsusb-otg` in 3.18 |
| **SMP via DT** | enable-method + ACC/SAW nodes. 3.18 used machine-level smp_ops |
| **SMD sysmon** | Added `obj-$(CONFIG_MSM_SYSMON_COMM) += sysmon.o sysmon-qmi.o` to Makefile. 4.4 only had GLINK sysmon |
| **fbtft bl_dev** | Stored in fbtft_par (not fb_info). Removed select FB_BACKLIGHT from Kconfig |
| **Prima in-tree** | At drivers/staging/prima/, KERNEL_BUILD=0, cfg80211 compat header |
| **GCC 7.4** | GCC 8+ breaks BUILD_BUG_ON/compiletime_assert. GCC 4.9 works but old |

## Toolchain

**Default: GCC 7.4.1** (Linaro 2019.02)
Path: `/opt/toolchains/gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf/bin/arm-linux-gnueabihf-`

Also available:
- GCC 4.9.4: `/opt/toolchains/gcc-linaro-4.9.4-2017.01-x86_64_arm-linux-gnueabihf/bin/arm-linux-gnueabihf-`
- GCC 8.3.0: `/opt/toolchains/gcc-arm-8.3-2019.03-x86_64-arm-linux-gnueabihf/bin/arm-linux-gnueabihf-` (kernel doesn't build)

## Build Fixes Applied

### Host toolchain (modern GCC on Debian 12)
- dtc: `extern YYLTYPE yylloc` in dtc-lexer (fixes -fno-common duplicate symbol)
- scm.h: `static inline` on `scm_is_secure_device` (fixes -fno-common)
- gcc-wrapper.py: ported to python3, warning-as-error disabled entirely

### GCC 7/8 compatibility
- Makefile: -Wno-{attribute-alias,stringop-truncation,stringop-overflow,sizeof-pointer-memaccess,packed-not-aligned}
- arch/arm/Makefile: -msoft-float in cc-option test for -march=armv7-a
- compiler-gcc.h: disable __compiletime_error for GCC >= 8
- compiler.h: disable __compiletime_error_fallback for GCC >= 8
- syscalls.h: disable __SC_TEST BUILD_BUG_ON for GCC >= 8

### Driver fixes
- wcnss_vreg.c: regulator_set_optimum_mode → regulator_set_load
- fbtft Kconfig: removed `select FB_BACKLIGHT` (CAF fb_info lacks fields)
- fbtft-core.c: par->info->bl_dev → par->bl_dev
- soc/qcom Makefile: added sysmon.o for CONFIG_MSM_SYSMON_COMM

### Prima wlan.ko fixes
- Kbuild: force KERNEL_BUILD=0, WLAN_ROOT=drivers/staging/prima
- Kconfig: select WIRELESS_EXT + WEXT_PRIV
- wlan_hdd_cfg80211.h: define SUPPORT_WDEV_CFG80211_VENDOR_EVENT_ALLOC (4.4 native)
- wlan_hdd_main.c: cfg80211_connect_bss +NL80211_TIMEOUT_UNSPECIFIED arg
- wlan_hdd_hostapd.c: STATION_INFO_ASSOC_REQ_IES guarded for < 4.0
- wlan_hdd_compat.h: STATION_INFO_* → BIT(NL80211_STA_INFO_*) mapping
- wlan_hdd_compat.c: wcnss_get_iris_name stub
- Disabled WLAN_NL80211_TESTMODE

## Boot Configuration
- No initramfs — kernel mounts p36 directly
- Cmdline: `root=/dev/mmcblk0p36 rootfstype=ext4 rootwait rw console=tty0 console=ttyHSL0,115200 fbcon=rotate:3 consoleblank=0`
- `.scmversion` file suppresses git hash in kernel version

## Key Patches from 3.18 (relative to stock CAF 4.4)

### SPI driver binding (msm8909-bq268.dts)
- Compatible: `qcom,spi-qup-v2.2.1` (matches 4.4 spi-qup.c)
- Clock-names: `"core","iface"` (not `"iface_clk","core_clk"`)

### fbtft display (drivers/staging/fbtft/)
- ST7735S init sequence from BQ268 bootloader (panel_st7735s_cmd.h)
- txbuflen=4096 to avoid SPI FIFO overrun
- Reset GPIO: GPIO_ACTIVE_LOW

### APR state (drivers/soc/qcom/qdsp6v2/apr_v3.c)
- Map APR_SUBSYS_UP → APR_SUBSYS_LOADED (MSM8909 has no separate LPASS)

## DTS Binding Compatibility (verified)
All critical DTS compatible strings match 4.4 drivers:
- `qcom,msm-qgic2` → irq-gic.c
- `qcom,rpmcc-8909` → clock-rpm-8909.c (ported)
- `qcom,gcc-8909` → clock-gcc-8909.c (ported)
- `qcom,spi-qup-v2.2.1` → spi-qup.c
- `qcom,smd` → smd.c / smd_init_dt.c
- `qcom,smem` → smem.c
- `qcom,smp2p` → smp2p.c
- `qcom,sdhci-msm` → sdhci-msm.c
- `qcom,spmi-pmic-arb` → spmi-pmic-arb.c
- `qcom,rpm-smd` → rpm-smd.c
- `qcom,usb-otg-snps` → phy-msm-usb.c (was qcom,hsusb-otg in 3.18)
- `qcom,kpss-acc-v2` → platsmp.c (SMP)

## Iteration Infrastructure
- `reboot-bootloader` binary: tools/reboot-bootloader/reboot-bootloader.c
- mkbootimg: tools/mkbootimg/mkbootimg.py
- Serial I/O via /dev/ttyACM0 (stty raw + timeout cat)
- SSH over WiFi: `sshpass -p bq268 ssh root@<device-ip>`
- Just recipes: build, bootimg, boot, flash, cycle, recycle, serial, dev-reboot

## Rootfs Requirements (for ~/bq268-pmos agent)
- wlan.ko at `/lib/modules/4.4.21-bq268/wlan.ko` (strip first — 53M → ~5M)
- WCNSS_qcom_cfg.ini at `/lib/firmware/wlan/prima/WCNSS_qcom_cfg.ini`
- reboot-bootloader at `/sbin/reboot-bootloader`
- USB gadget: configfs-based (not android_usb sysfs)
- WiFi: `cat /dev/wcnss_wlan &` before `insmod wlan.ko`

## Commit History
```
2da91ef5 Switch default toolchain to GCC 7.4
f6cd080a GCC 7.4/8.3 toolchain compatibility fixes
3179173e GCC 12 compatibility: arch fix + disable gcc-wrapper warnings
bef50879 Add prima wlan.ko WiFi driver for MSM8909
4838f60f Add CLAUDE.md for CAF 4.4 repo
f11d1f0c WIP: Add MSM8909 audio infrastructure (codec not yet compiling)
329e4eaf Replace stock ST7735R init with BQ268 ST7735S sequence
ed27201a USB OTG compatible fix + APR subsystem state for MSM8909
5e4ff276 Enable SMP, PIL/SSR, and fbtft for MSM8909
e7507ccf Add MSM8909 platform support to CAF 4.4 kernel
```

## Next Steps / Roadmap

### Immediate: First Boot Test
- Flash `output/boot-2da91ef5.img` via fastboot boot (temporary)
- Watch ttyHSL0 serial or /dev/ttyACM0 for console
- Capture dmesg, identify what works and what panics/hangs

### After Boot Works
1. **USB ACM console** — verify configfs gadget creates /dev/ttyGS0 on device
   - If not: may need Alpine usb-gadget init script update for configfs
   - 3.18 used android_usb sysfs, 4.4 uses /sys/kernel/config/usb_gadget/
2. **Display** — verify fbtft fbcon on ST7735S
3. **WiFi** — strip + deploy wlan.ko, test with wpa_supplicant
4. **Modem** — verify PIL loads firmware, SMD channels open

### Audio (Phase 5, parked)
Remaining API fixes for msm8x16-wcd.c:
- `spmi_get_resource()` → `platform_get_resource()` or `of_address_to_resource()`
- `codec->driver->reg_cache_size` removed in 4.4
- MBHC callback signatures: `struct wcd_mbhc *` vs `struct snd_soc_codec *`
- `audio_notifier` integration (4.4 adds SSR/PDR layers)
- Estimated: 2-3 days of focused work

### GCC 8+ (parked)
`__compiletime_assert` / `BUILD_BUG_ON` produces false `.err` in assembler output.
Root cause: GCC 8 constant folding evaluates paths that GCC 7 optimized away.
Upstream fix is in kernel 4.17+ (commit 1d5a451a and friends).
Would need backporting ~5 commits from 4.17 to fully fix.
