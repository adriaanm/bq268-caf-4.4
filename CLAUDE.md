# BQ268 Kernel — CAF 4.4 Branch

## Goal

Port the MSM8909 BQ268 walkie-talkie from a working 3.18 CAF kernel to 4.4 CAF. All hardware must work: display, USB, WiFi, modem, audio.

## Non-goals

- Mainline kernel support (we use CAF's legacy clock framework, vendor drivers)
- Android userspace (we run Alpine Linux / OpenRC)
- GCC 8+ support (parked — needs backporting 4.17 compiletime_assert fixes)

## Reference

- **3.18 CAF kernel**: `~/bq268-caf_msm-3.18` (read-only reference — request changes through user). Note: 3.18 modem never tested with Alpine; stock kernel is Android-only.
- **Alpine rootfs**: `~/bq268-alpine` (read-only reference — request changes through user)
- **Toolchain**: GCC 7.4.1 at `/opt/toolchains/gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf/`
- **Rootfs**: Alpine 3.21.3 on eMMC partition 36 (built/managed by `~/bq268-alpine`)
- **Bootloader (aboot)**: `~/bq268-aboot` — LK source + decompiled stock aboot + docs (memory layout, RPM/DDR, TZ interface, boot analysis)
- **EDL tool + device dump**: `~/bq268-edl` — Go-based EDL backup/restore tool; `dump/` has all eMMC partitions including stock `boot.bin`
- **Lineage/Android ref**: `~/bq268-lineage` — LineageOS/Android reference tree
- **Learnings & architecture decisions**: see `LEARNINGS.md`

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

Tasks track what needs doing. They live in git notes on HEAD.

- **`just tasks`** — show current tasks
- **`just task-add "description"`** — add a new task
- **`just task-start "pattern"`** — mark in-progress
- **`just task-done "pattern"`** — mark done
- **`just experiments`** — show experiment log with tasks

When starting work, run `just tasks` first. When finishing a task, run `just task-done`. When discovering new work, run `just task-add`. Keep the list current — move tasks forward when committing.

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
| Modem Q6 stalled init | **Open** | PIL boot + auth OK. Q6 creates IPCRTR + SSCTL, but never creates DIAG/DATA/APR channels or QMI services. Watchdog at ~40-60s. All AP-side drivers enabled (DIAG, BAM_DMUX, smd_pkt, QMI, MEM_SHARE, QDSP6_SSR). SMEM v0x000B confirmed (same as 3.18). SMD/SMSM code identical. Firmware verified matching modem partition. Modem stall is internal — not caused by missing AP-side SMD handlers. Modem firmware strings suggest A2 task blocked waiting for "apps action". |
| WCD codec regmap | **Open** | msm8x16-wcd uses old .read/.write callbacks, not regmap. `snd_soc_cache_sync()` crashes on NULL regmap in 4.4. Guarded with NULL check (skips sync). Blocks audio, not modem. |
| sleep() hangs with lpm-levels | **Workaround**: lpm-levels disabled in DTS | Timer dies when CPU enters idle via lpm-levels. |
| Bus scaling crashes | **Workaround**: QCOM_BUS_SCALING + BIMC_BWMON disabled | Kernel hangs before init when enabled. Needs DT or driver debug. |
| Broadcast timer (arch_mem_timer) | **Open** | Selected as broadcast device, in oneshot mode, but 0 interrupts ever. Blocks deep idle. |
