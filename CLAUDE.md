# BQ268 Kernel — CAF 4.4 Branch

## Goal

Port the MSM8909 BQ268 walkie-talkie from a working 3.18 CAF kernel to 4.4 CAF. All hardware must work: display, USB, WiFi, modem, audio.

## Non-goals

- Mainline kernel support (we use CAF's legacy clock framework, vendor drivers)
- Android userspace (we run Alpine Linux / OpenRC)
- GCC 8+ support (parked — needs backporting 4.17 compiletime_assert fixes)

## Reference

- **3.18 working kernel**: `~/bq268-caf_msm-3.18`
- **Toolchain**: GCC 7.4.1 at `/opt/toolchains/gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf/`
- **Rootfs**: Alpine 3.21.3 on eMMC partition 36
- **Learnings & architecture decisions**: see `LEARNINGS.md`

## Reproducibility

Every repeated command goes in the `justfile`. Run `just` to list recipes.

## Workflow: Commit Before Flash

1. **Commit first** — git commit before building/flashing
2. **Build and boot** — `just cycle` (builds initramfs image + boots via fastboot)
3. **Record outcome** — `just note "PASS: description"` or `just note "FAIL: description"`

## Workflow: Iteration Cycle

The device boots our 4.4 kernel via `fastboot boot` (RAM, not flashed). The 3.18 kernel remains on the boot partition. Reboot goes through 3.18 as intermediary because SPMI/PON doesn't probe on 4.4 yet.

- **`just cycle`** — build initramfs image → `fastboot boot` → wait for serial → grab dmesg (requires device in fastboot)
- **`just recycle`** — reboot current device → cycle (fully autonomous, no manual intervention)
- **`just serial "cmd"`** — run a command on the device via USB serial (`/dev/ttyACM0`)
- **`just dev-reboot`** — two-hop reboot: 4.4 reboot → 3.18 → reboot-bootloader → fastboot

The serial console is USB ACM via configfs gadget on `ttyGS0` (device) / `ttyACM0` (host). The init script respawns the shell if it exits.

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
| SMP via DT | enable-method + ACC/SAW nodes (3.18 used machine smp_ops) |
| GCC 7.4 | GCC 8+ breaks BUILD_BUG_ON; GCC 4.9 works but old |
| lpm-levels disabled | Breaks timer in idle; sleep hangs. WFI via default arch_cpu_idle works. |
| always-on arch timer | Prevents C3STOP handoff to broken broadcast timer |
| Two-hop reboot | 4.4 SPMI children don't enumerate → no PON → reboot via 3.18 |

## Known Issues

| Issue | Status | Notes |
|-------|--------|-------|
| sleep() hangs with lpm-levels | **Workaround**: lpm-levels disabled in DTS | Timer works in periodic (402 IRQs boot) and during busywait (13920 IRQs), but dies when CPU enters idle via lpm-levels. Not C3STOP, not deep idle, not broadcast enable — something in cpuidle registration or probe breaks the per-CPU timer. |
| Bus scaling crashes | **Workaround**: QCOM_BUS_SCALING + BIMC_BWMON disabled | Kernel hangs before init when enabled. Needs DT or driver debug. |
| SPMI child enumeration | **Open** | PMIC ARB probes but no child devices (pm8909@0, PON, etc). Blocks QPNP PON (reboot-to-bootloader) and other PMIC drivers. |
| Broadcast timer (arch_mem_timer) | **Open** | Selected as broadcast device, in oneshot mode, but 0 interrupts ever. Blocks deep idle (standalone_pc, pc). |
