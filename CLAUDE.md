# BQ268 Kernel — CAF 4.4 Branch

## Goal

Port the MSM8909 BQ268 walkie-talkie from a working 3.18 CAF kernel to 4.4 CAF. All hardware must work: display, USB, WiFi, modem, audio.

## Non-goals

- Mainline kernel support (we use CAF's legacy clock framework, vendor drivers)
- Android userspace (we run Alpine Linux / OpenRC)
- GCC 8+ support (parked — needs backporting 4.17 compiletime_assert fixes)

## Branch Provenance

The `bq268` branch is based on CAF commit `31516ed73500e` from the `kernel.lnx.4.4` tree (SUBLEVEL 4.4.21). This was found by searching the full CAF history for the commit with the smallest diff against our original shallow-clone base (`5cfb00b92fdc4`). See `stable-upgrade-4.4.md` for the full analysis.

On top of this base: cherry-pick of `2dd3d52f9567d` (osq_lock `smp_wmb()` fix for ARM memory ordering), then all custom commits from the original `bq268-orig-shallow` branch.

**Remotes:**
- `origin` — `https://git.codelinaro.org/clo/la/kernel/msm-4.4.git` (CAF upstream)
- `android-linux-stable` — `https://github.com/android-linux-stable/msm-4.4.git` (stable merges)
- `github` — `https://github.com/adriaanm/bq268-caf-4.4.git` (our repo)

**Old branches (preserved for reference):**
- `bq268-orig-shallow` — original working kernel on shallow-clone CAF base
- `bq268-rebased-r42-backup` — failed rebase onto r42 (4.4.205, too large a jump)

## Reference

- **3.18 CAF kernel**: `~/bq268-caf_msm-3.18` (read-only reference — request changes through user). Note: 3.18 modem never tested with Alpine; stock kernel is Android-only.
- **Alpine rootfs**: `~/bq268-alpine` (read-only reference — request changes through user)
- **Toolchain**: GCC 7.4.1 at `/opt/toolchains/gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf/`
- **Rootfs**: Alpine 3.21.3 on eMMC partition 36 (built/managed by `~/bq268-alpine`)
- **Bootloader (aboot)**: `~/bq268-aboot` — LK source + decompiled stock aboot + docs (memory layout, RPM/DDR, TZ interface, boot analysis)
- **EDL tool + device dump**: `~/bq268-edl` — Go-based EDL backup/restore tool; `dump/` has all eMMC partitions including stock `boot.bin`
- **Prima WLAN upstream**: `~/prima-upstream` — cloned from `https://git.codelinaro.org/clo/la/platform/vendor/qcom-opensource/wlan/prima` branch `LA.UM.7.7.c26` (MSM8909-targeted). In-tree at `drivers/staging/prima/`, updated to tag `LA.UM.7.7.c26-11700-8x09.0`. Kbuild/Kconfig/compat shims are ours; the rest is upstream. To update: copy tree from `~/prima-upstream`, restore Kbuild/Kconfig/compat files, re-apply cfg80211 and indentation fixes.
- **WireGuard compat module**: `~/wireguard-linux-compat` — cloned from `https://git.zx2c4.com/wireguard-linux-compat` (tag `v1.0.20220627`). Out-of-tree module for kernels 3.10–5.5. Build: `make -C ~/wireguard-linux-compat/src KERNELDIR=$(pwd) O=$(pwd)/output CROSS_COMPILE=...arm-linux-gnueabihf- ARCH=arm -j$(nproc)`. Produces `wireguard.ko`, deploy to `/lib/modules/$(kernelrelease)/`.
- **Learnings & architecture decisions**: see `LEARNINGS.md`
- **Rebase analysis & stable upgrade**: see `stable-upgrade-4.4.md`

## Reproducibility

Every repeated command goes in the `justfile`. Run `just` to list recipes.

## Workflow: Commit Before Flash

1. **Commit first** — git commit before building/flashing
2. **Build** — `just bootimg` (builds kernel + modules + boot.img)
3. **Reboot to fastboot** — `just dev-reboot` (fast — do this after build, not before)
4. **Flash or boot** — `just flash` (permanent) or `just boot` (RAM-only)
5. **Record outcome** — `just note "PASS: description"` or `just note "FAIL: description"`

**Important**: Build first, then reboot. The build is slow (~minutes), the reboot is fast (~seconds). Don't leave the device sitting in fastboot while building.

## Workflow: Iteration Cycle

- **`just bootimg`** — full build: kernel + modules + boot.img
- **`just boot`** — fastboot boot (RAM, temporary — requires device in fastboot)
- **`just flash`** — fastboot flash boot partition (permanent — requires device in fastboot)
- **`just dev-reboot`** — reboot to fastboot via `/usr/local/bin/reboot-bootloader` on device
- **`just grab-dmesg`** — capture dmesg from device via serial
- **`just serial "cmd"`** — run a command on the device via USB serial (`/dev/ttyACM0`)

The serial console is USB ACM via configfs gadget on `ttyGS0` (device) / `ttyACM0` (host). The Alpine rootfs (p36) sets up USB gadget via OpenRC (`usb-gadget` at boot, `usb-gadget-ecm` at default runlevel).

**Timing notes**: OpenRC boot takes ~130s for serial to appear. ECM rebind drops serial briefly — wait 30s after serial appears before using it. For long-running tests, prefer `just serial 'cmd1; cmd2; sync'` in a single invocation over separate commands.

## Workflow: Defconfig Changes

CAF renamed many `CONFIG_MSM_*` to `CONFIG_QCOM_*` in 4.4. Stale 3.18 names are silently ignored. After adding a config symbol, always verify it made it into the built config:

```sh
grep 'YOUR_SYMBOL' output/.config
```

To check all defconfig symbols at once:

```sh
grep '^CONFIG_' arch/arm/configs/msm8909_defconfig | while read line; do
    sym=$(echo "$line" | cut -d= -f1)
    grep -q "^${sym}=" output/.config || echo "MISSING: $line"
done
```

Common causes of silent drops: parent menu disabled (e.g. `INPUT_MISC`), missing bus dependency (e.g. `SPMI`), renamed symbol.

## Workflow: Tasks

Tasks live in `TASKS.md`. Check it at the start of each session. Mark items `[x]` when done, add new items as discovered.

## Workflow: Porting from 3.18

When porting a subsystem from 3.18 to 4.4:

1. **Study git history** of both kernels for the subsystem. Understand how the 4.4 code evolved from 3.18, what was added/removed, and why.
2. **Compare DTS nodes** — compatible strings, register addresses, clock names often changed between kernel versions.
3. **Check Kconfig symbol renames** — CAF renamed many `CONFIG_MSM_*` to `CONFIG_QCOM_*` in 4.4. The defconfig may have stale 3.18 names that are silently ignored.
4. **Verify the code path is actually compiled** — grep the built `.config` (in `output/.config`), not just the defconfig.
5. **Minimal diff** — port only what's needed, don't bring over dead code.

## Key Architecture Decisions

| Decision | Rationale |
|----------|-----------|
| COMMON_CLK_MSM only | Legacy CAF clock framework; mainline COMMON_CLK conflicts |
| USB configfs | 4.4 removed USB_G_ANDROID; Alpine handles configfs |
| Non-PSCI idle | MSM8909 TZ has no PSCI; ported SCM-based idle from 3.18 |
| SMP via DT | enable-method + ACC/SAW nodes (3.18 used machine smp_ops). All 4 CPUs online. |
| eMMC rootfs | Alpine on p36, no initramfs. Firmware at `/lib/firmware/` (pre-extracted from modem partition). |
| GCC 7.4 | GCC 8+ breaks BUILD_BUG_ON; GCC 4.9 works but old |
| lpm-levels disabled | Breaks timer in idle; sleep hangs. WFI via default arch_cpu_idle works. |
| always-on arch timer | Prevents C3STOP handoff to broken broadcast timer |
| fbtft display (not MDP3) | 160×128 ST7735S SPI panel via `fb_st7735r` (fbtft staging driver) on SPI5 (BLSP1 QUP5). MDSS SPI panel driver disabled. SPI uses BAM DMA via CAF `spi_qsd.c`. |
| PPP over SMD | Modem data path is PPP over SMD (smd7), not BAM DMUX. AT commands for APN/PDP, then pppd over the SMD tty. |
| ~~BAM DMUX~~ | ~~Not used on MSM8909~~ — modem never sets SMSM A2_POWER_CONTROL; 0x4044000 not mapped in iomem. |
| ~~Two-hop reboot~~ | ~~4.4 SPMI children don't enumerate → no PON → reboot via 3.18~~ (resolved: SPMI+PON work, direct reboot-to-bootloader from 4.4) |

## Known Issues

| Issue | Status | Notes |
|-------|--------|-------|
| SMP broken | **Resolved** | Fixed: `scm_set_boot_addr_mc()` + 3.18 `arm_release_secondary` register sequence. All 4 CPUs online. |
| WiFi (WCNSS) | **Resolved** | Working: wlan0 up, IPv4+IPv6, internet connectivity. Prima wlan.ko module. |
| SPMI child enumeration | **Resolved** | Fixed: 4.4-style DT bindings + CONFIG_MFD_SPMI_PMIC. |
| Modem Q6 stalled init | **Resolved** | Root cause: modem needs `rmt_storage` daemon for EFS partition I/O. Without it, modem init stalls at 55s watchdog. With rmt_storage running, modem fully initializes: APR audio, DIAG, DATA channels all created. |
| BAM DMUX data path | **Won't fix** | MSM8909 modem doesn't use BAM DMUX — data path is PPP over SMD. Modem never sets SMSM A2_POWER_CONTROL; 0x4044000 not in iomem. BAM DMUX/RMNET configs disabled. |
| Modem data (PPP) | **Resolved** | Full cellular data via PPP over SMD (smd7). pppd on Alpine brings up ppp0 interface. |
| Spontaneous reboot | **Resolved** | Was instant SoC death during fast fbcon output. Fixed by backporting MIPI DBI SPI transfer discipline from mainline + `spi_qsd.c` `is_dma_mapped` fix. See `hard_crash.md`. |
| WCD codec regmap | **Resolved** | Added regmap wrapper (REGCACHE_FLAT). Sound card registers, audio playback works via Q6 DSP. |
| lpm-levels deep idle | **Won't fix** | Stock OEM kernel ships with `lpm_levels.sleep_disabled=1`. Broadcast timer (arch_mem_timer) never fires (0 interrupts) — likely silicon/TZ limitation. Per-CPU power collapse savings marginal (6-18 mW). WFI-only idle is fine. |
| Bus scaling crashes | **Workaround**: QCOM_BUS_SCALING + BIMC_BWMON disabled | Kernel hangs before init when enabled. Needs DT or driver debug. Related to spontaneous reboot — no DDR QoS arbitration. |
