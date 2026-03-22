# Tasks

## High Priority — Modem Bringup

- [x] **~~Fix hyp_assign_phys failure for rmtfs shared memory~~** — Error is already non-fatal (probe continues, UIO devices created). MSM8909 TZ doesn't implement `MEM_PROT_ASSIGN_ID` (0x16) but shared memory at 0x87c00000 is statically accessible by both HLOS and MSS. Both 3.18 and 4.4 have the same call; it likely also fails silently on stock. No fix needed.

- [x] **~~Write/port rmt_storage daemon for Alpine.~~** Done in `~/bq268-alpine/tools/rmt_storage.c`. Serves modem EFS via `/dev/uio0` (rmtfs shared mem). Bug found: `phys_offset` in RW_IOVEC is buffer-relative, not absolute — fixed by adding `shmem.phys_addr` base.

- [x] **~~Test modem with rmt_storage running.~~** Modem fully initializes: APR audio OPENED, DIAG channels OPENED, DATA1-4/DS channels created (modem OPENING, AP CLOSED). No watchdog crash. EFS read+write confirmed working.

- [ ] **BAM DMUX data path handshake.** SMSM A2_POWER_CONTROL never set by modem. BAM hardware confirmed working (force init registers BAM 0x04044000, 6 pipes, ver 0x25). But forcing it crashes modem: `a2_power.c:2783:A2 Assertion Failed` — A2 task is alive but has unmet internal precondition. Ruled out: all AP daemons, SIM card, IPC_ROUTER_SECURITY, memshare, SMSM state. Needs modem-side DIAG logs to identify what A2 is waiting for.

- [x] **~~Port `msm_rmnet_bam.c` from 3.18.~~** Done. Copied from 3.18, adapted `net_device_stats` to `dev->stats`, stubbed flow control ioctls (need `CONFIG_NET_SCHED`). Driver registers platform drivers for `bam_dmux_ch_0`-`bam_dmux_ch_20` at boot. `CONFIG_USB_BAM` crashes at probe — disabled.

- [ ] **Get modem DIAG logs working.** DIAG SMD channels are OPENED (DIAG, DIAG_CMD, DIAG_CNTL, DIAG_2, DIAG_2_CMD). Need to capture modem-side logs to understand why A2 task doesn't set SMSM A2_POWER_CONTROL. Kernel has `CONFIG_DIAG_CHAR=y` (with `late_initcall` fix). Options: (1) Use `/dev/diag` + DIAG userspace tool to extract modem F3 messages, (2) Check `~/bq268-lineage` for `ssr_diag` or DIAG tools, (3) Use postmarketOS `diag-router` package. Key: modem's `a2_power.c` has the logic — DIAG F3 messages from A2 task should show what precondition blocks A2_POWER_CONTROL.

## Normal Priority

- [ ] Fix WCD codec regmap for 4.4 ASoC cache API — msm8x16-wcd uses old `.read`/`.write` callbacks, not regmap. `snd_soc_cache_sync()` needs regmap in 4.4. Blocks audio, not modem.

- [ ] Investigate DIAG_CHAR=y EDL crash — `late_initcall` workaround in place. `module_init` causes PMIC reset (not normal panic). Likely USB subsystem not ready at `device_initcall` level.
