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

Kernel version: **4.4.21-bq268** (not yet booted)
Base: CAF LA.UM.5.7.c25 (MSM8916 branch) with MSM8909 support ported from 3.18
Rootfs: Alpine 3.21.3 on userdata (p36), OpenRC (same as 3.18)

### Ported from 3.18 (compiles, not yet tested)
- **Clock drivers**: clock-gcc-8909.c, clock-rpm-8909.c, clock-a7.c (legacy CAF COMMON_CLK_MSM)
- **Pinctrl**: pinctrl-msm8909.c
- **Board**: board-8909.c (DT-based SMP via KPSS ACC v2)
- **DTS**: Full msm8909.dtsi + 37 supporting dtsi, msm8909-bq268.dts
- **SMP**: ACC/SAW2 nodes, enable-method=qcom,kpss-acc-v2 on all 4 CPUs
- **USB**: Compatible changed to qcom,usb-otg-snps, configfs gadget (not android.c)
- **fbtft**: ST7735S init sequence from 3.18, backlight fix (par->bl_dev)
- **PIL/SSR**: Enabled with SMD-based sysmon (sysmon.o added to Makefile)
- **APR**: SUBSYS_UP→SUBSYS_LOADED mapping in apr_v3.c
- **WCNSS**: Config enabled (needs PIL for firmware load)

### Not yet working
- **Audio**: WCD codec + machine driver copied but not compiling (API changes)
- **Modem**: PIL enabled but DTS/firmware path not verified

### Key Differences from 3.18
- **Clock framework**: COMMON_CLK_MSM (legacy), NOT mainline COMMON_CLK (they conflict)
- **USB gadget**: configfs (USB_CONFIGFS_ACM), not android.c (USB_G_ANDROID removed)
- **SMP**: DT enable-method + ACC/SAW nodes (3.18 used machine-level smp_ops)
- **Sysmon**: SMD-based sysmon.o wired in (4.4 only had GLINK sysmon)
- **fbtft**: bl_dev in fbtft_par struct (4.4 fb_info lacks backlight fields)

## Toolchain

**GCC 4.9.4** — same as 3.18.

## Build Fixes Applied

- dtc: `extern YYLTYPE yylloc` (host GCC -fno-common)
- scm.h: `static inline` on `scm_is_secure_device`
- gcc-wrapper.py: python3, dma-mapping.c allowlisted, ported audio files suppressed
- fbtft Kconfig: removed `select FB_BACKLIGHT` (CAF fb_info lacks fields)
- soc/qcom Makefile: added `obj-$(CONFIG_MSM_SYSMON_COMM) += sysmon.o sysmon-qmi.o`

## Boot Configuration
- Cmdline: `root=/dev/mmcblk0p36 rootfstype=ext4 rootwait rw console=tty0 console=ttyHSL0,115200 fbcon=rotate:3 consoleblank=0`
- `.scmversion` file suppresses git hash in kernel version

## Iteration Infrastructure
- `reboot-bootloader` binary: tools/reboot-bootloader/reboot-bootloader.c
- mkbootimg: tools/mkbootimg/mkbootimg.py
- Just recipes: build, bootimg, boot, flash, cycle, recycle, serial, dev-reboot
