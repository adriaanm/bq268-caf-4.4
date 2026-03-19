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
2. **Build and flash** — `just bootimg`, then `just boot`
3. **Record outcome** — `just note "PASS: description"` or `just note "FAIL: description"`

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
