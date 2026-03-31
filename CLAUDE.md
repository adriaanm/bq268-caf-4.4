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
2. **Build and boot** — `just cycle` (builds kernel + boot.img, boots via fastboot)
3. **Record outcome** — `just note "PASS: description"` or `just note "FAIL: description"`

## Workflow: Iteration Cycle

The device boots our 4.4 kernel via `fastboot boot` (RAM, not flashed). The 3.18 kernel remains on the boot partition. Reboot-to-bootloader works from both kernels.

- **`just cycle`** — build kernel + boot.img (eMMC rootfs) → `fastboot boot` → wait for serial → grab dmesg (requires device in fastboot)
- **`just recycle`** — reboot current device → cycle (fully autonomous, no manual intervention)
- **`just serial "cmd"`** — run a command on the device via USB serial (`/dev/ttyACM0`)
- **`just dev-reboot`** — reboot to fastboot via `/usr/local/bin/reboot-bootloader` on device

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
| ~~Two-hop reboot~~ | ~~4.4 SPMI children don't enumerate → no PON → reboot via 3.18~~ (resolved: SPMI+PON work, direct reboot-to-bootloader from 4.4) |

## Known Issues

| Issue | Status | Notes |
|-------|--------|-------|
| SMP broken | **Resolved** | Fixed: `scm_set_boot_addr_mc()` + 3.18 `arm_release_secondary` register sequence. All 4 CPUs online. |
| WiFi (WCNSS) | **Resolved** | Working: wlan0 up, IPv4+IPv6, internet connectivity. Prima wlan.ko module. |
| SPMI child enumeration | **Resolved** | Fixed: 4.4-style DT bindings + CONFIG_MFD_SPMI_PMIC. |
| Modem Q6 stalled init | **Resolved** | Root cause: modem needs `rmt_storage` daemon for EFS partition I/O. Without it, modem init stalls at 55s watchdog. With rmt_storage running, modem fully initializes: APR audio, DIAG, DATA channels all created. |
| BAM DMUX data path | **Open** | Modem A2 task alive but never sets SMSM A2_POWER_CONTROL. BAM HW works (force init: 0x04044000, 6 pipes). Forcing crashes modem: `a2_power.c:2783:A2 Assertion Failed`. All AP-side causes ruled out. Need modem DIAG logs to identify A2 precondition. `msm_rmnet_bam.c` ported, ready to create rmnet interfaces once BAM initializes. |
| WCD codec regmap | **Open** | msm8x16-wcd uses old .read/.write callbacks, not regmap. `snd_soc_cache_sync()` crashes on NULL regmap in 4.4. Guarded with NULL check (skips sync). Blocks audio, not modem. |
| lpm-levels deep idle | **Won't fix** | Stock OEM kernel ships with `lpm_levels.sleep_disabled=1`. Broadcast timer (arch_mem_timer) never fires (0 interrupts) — likely silicon/TZ limitation. Per-CPU power collapse savings marginal (6-18 mW). WFI-only idle is fine. |
| Bus scaling crashes | **Workaround**: QCOM_BUS_SCALING + BIMC_BWMON disabled | Kernel hangs before init when enabled. Needs DT or driver debug. |
