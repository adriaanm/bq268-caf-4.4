# Tasks

## High Priority — Modem Bringup
- [x] **~~Disable CONFIG_ANDROID_PARANOID_NETWORK~~** Set `CONFIG_ANDROID_PARANOID_NETWORK=n` in defconfig. Verified in output/.config.

- [x] **~~Fix hyp_assign_phys failure for rmtfs shared memory~~** — Error is already non-fatal (probe continues, UIO devices created). MSM8909 TZ doesn't implement `MEM_PROT_ASSIGN_ID` (0x16) but shared memory at 0x87c00000 is statically accessible by both HLOS and MSS. Both 3.18 and 4.4 have the same call; it likely also fails silently on stock. No fix needed.

- [x] **~~Write/port rmt_storage daemon for Alpine.~~** Done in `~/bq268-alpine/tools/rmt_storage.c`. Serves modem EFS via `/dev/uio0` (rmtfs shared mem). Bug found: `phys_offset` in RW_IOVEC is buffer-relative, not absolute — fixed by adding `shmem.phys_addr` base.

- [x] **~~Test modem with rmt_storage running.~~** Modem fully initializes: APR audio OPENED, DIAG channels OPENED, DATA1-4/DS channels created (modem OPENING, AP CLOSED). No watchdog crash. EFS read+write confirmed working.

- [ ] **BAM DMUX data path handshake.** SMSM A2_POWER_CONTROL never set by modem. BAM hardware confirmed working (force init registers BAM 0x04044000, 6 pipes, ver 0x25). But forcing it crashes modem: `a2_power.c:2783:A2 Assertion Failed` — A2 task is alive but has unmet internal precondition. Ruled out: all AP daemons, SIM card, IPC_ROUTER_SECURITY, memshare, SMSM state. Needs modem-side DIAG logs to identify what A2 is waiting for.

- [x] **~~Port `msm_rmnet_bam.c` from 3.18.~~** Done. Copied from 3.18, adapted `net_device_stats` to `dev->stats`, stubbed flow control ioctls (need `CONFIG_NET_SCHED`). Driver registers platform drivers for `bam_dmux_ch_0`-`bam_dmux_ch_20` at boot. `CONFIG_USB_BAM` crashes at probe — disabled.

- [ ] **Get modem DIAG logs working.** Tool: `tools/diag_read.c`. Build: `just diag-build`. Deploy: `just diag-deploy`. **Partially working:** /dev/diag opens, SWITCH_LOGGING to MEMORY_DEVICE_MODE succeeds, reader thread (pthread) receives mask updates (MSG/EVENT/LOG), SET_ALL_MSG_MASK command sent and propagated to modem. **Not working yet:** No F3 messages arrive — modem DIAG DATA SMD channel (ch9) shows zero traffic in both directions. Modem CNTL channel has unread data (APPS RDPTR=0 vs MDMSW WRPTR=0x1B6B). **Known issues:** (1) DIAG session cleanup on close is broken — stale `md_session_mask` blocks subsequent runs, requires reboot. (2) `USER_SPACE_RAW_DATA_TYPE` write path blocks if `in_busy_pktdata=1` — solved via pthread reader thread. (3) HDLC toggle ioctl causes D-state (kernel mutex contention in `diag_update_md_clients`) — disabled for now. **Next steps:** (a) Investigate why modem CNTL data isn't fully consumed by APPS, (b) try per-SSID mask (SET_MSG_MASK) instead of SET_ALL, (c) consider USB DIAG gadget approach as alternative to /dev/diag.

## Normal Priority

- [ ] Fix WCD codec regmap for 4.4 ASoC cache API — msm8x16-wcd uses old `.read`/`.write` callbacks, not regmap. `snd_soc_cache_sync()` needs regmap in 4.4. Blocks audio, not modem.

- [ ] Investigate DIAG_CHAR=y EDL crash — `late_initcall` workaround in place. `module_init` causes PMIC reset (not normal panic). Likely USB subsystem not ready at `device_initcall` level.

- [x] ~~CONFIG_KEYBOARD_MATRIX=y to fix gpio-keys~~ Added to defconfig, verified in output/.config.

- [x] ~~screen blanking~~ Removed `consoleblank=0` from cmdline in justfile. fbcon default 10-min blank timer now works (draws black). Backlight stays on (PM8909 MPP4 current sink, needs qpnp-leds driver for proper control — not yet ported).

- [ ] Port qpnp-leds for LCD backlight control — PM8909 MPP4 drives the ST7735S backlight as a current sink (20mA, `bkl-trigger`). 3.18 DTS has `qcom,led_mpp_4` under `qcom,leds@a300`. Need `CONFIG_LEDS_QPNP` or equivalent on 4.4, plus DTS node. Would enable proper fb_blank backlight off via the backlight subsystem.
