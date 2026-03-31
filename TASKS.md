# Tasks

## High Priority — Modem Bringup
- [x] **~~Disable CONFIG_ANDROID_PARANOID_NETWORK~~** Set `CONFIG_ANDROID_PARANOID_NETWORK=n` in defconfig. Verified in output/.config.

- [x] **~~Fix hyp_assign_phys failure for rmtfs shared memory~~** — Error is already non-fatal (probe continues, UIO devices created). MSM8909 TZ doesn't implement `MEM_PROT_ASSIGN_ID` (0x16) but shared memory at 0x87c00000 is statically accessible by both HLOS and MSS. Both 3.18 and 4.4 have the same call; it likely also fails silently on stock. No fix needed.

- [x] **~~Write/port rmt_storage daemon for Alpine.~~** Done in `~/bq268-alpine/tools/rmt_storage.c`. Serves modem EFS via `/dev/uio0` (rmtfs shared mem). Bug found: `phys_offset` in RW_IOVEC is buffer-relative, not absolute — fixed by adding `shmem.phys_addr` base.

- [x] **~~Test modem with rmt_storage running.~~** Modem fully initializes: APR audio OPENED, DIAG channels OPENED, DATA1-4/DS channels created (modem OPENING, AP CLOSED). No watchdog crash. EFS read+write confirmed working.

- [ ] **BAM DMUX data path handshake.** SMSM A2_POWER_CONTROL never set by modem. BAM hardware confirmed working (force init registers BAM 0x04044000, 6 pipes, ver 0x25). But forcing it crashes modem: `a2_power.c:2783:A2 Assertion Failed`. **Key finding (2026-03-23):** Modem defaults to `shutting-down` operating mode — must send `qmicli --dms-set-operating-mode=online` (stock Android's rild does this). After setting online: RF works (UMTS scan, sees MCC228/MNC3 Swisscom), NAS status `limited` (no SIM). A2 still not set — may require PS-attached state (needs SIM). Next: test with SIM card inserted.

- [x] **~~Port `msm_rmnet_bam.c` from 3.18.~~** Done. Copied from 3.18, adapted `net_device_stats` to `dev->stats`, stubbed flow control ioctls (need `CONFIG_NET_SCHED`). Driver registers platform drivers for `bam_dmux_ch_0`-`bam_dmux_ch_20` at boot. `CONFIG_USB_BAM` crashes at probe — disabled.

- [ ] **Get modem DIAG logs working.** Tool: `tools/diag_read.c`. Build: `just diag-build`. Deploy: `just diag-deploy`. **Partially working:** /dev/diag opens, SWITCH_LOGGING to MEMORY_DEVICE_MODE succeeds, reader thread (pthread) receives mask updates (MSG/EVENT/LOG), SET_ALL_MSG_MASK command sent and propagated to modem. **Not working yet:** No F3 messages arrive — modem DIAG DATA SMD channel (ch9) shows zero traffic in both directions. Modem CNTL channel has unread data (APPS RDPTR=0 vs MDMSW WRPTR=0x1B6B). **Known issues:** (1) DIAG session cleanup on close is broken — stale `md_session_mask` blocks subsequent runs, requires reboot. (2) `USER_SPACE_RAW_DATA_TYPE` write path blocks if `in_busy_pktdata=1` — solved via pthread reader thread. (3) HDLC toggle ioctl causes D-state (kernel mutex contention in `diag_update_md_clients`) — disabled for now. **Next steps:** (a) Investigate why modem CNTL data isn't fully consumed by APPS, (b) try per-SSID mask (SET_MSG_MASK) instead of SET_ALL, (c) consider USB DIAG gadget approach as alternative to /dev/diag.

## Normal Priority — Audio & Hardware

- [ ] **Port qpnp-linear-charger from 3.18.** `qpnp-linear-charger.c` (compatible `qcom,qpnp-linear-charger`) missing from CAF 4.4 — dropped in favor of `qpnp-smb2` for newer PMICs. PM8909 needs the old driver. DTS nodes already correct (`pm8909_chg` in `msm-pm8909.dtsi` + overrides in bq268 DTS). PMIC charges in hardware without the driver, but no `/sys/class/power_supply/battery` for status/control.

- [ ] **Port qpnp-vm-bms from 3.18.** `qpnp-vm-bms.c` (compatible `qcom,qpnp-vm-bms`) also missing from CAF 4.4. Provides battery SOC estimation, voltage/current reporting. DTS node `pm8909_bms` already defined. Without it, battmon daemon reads VADC directly as a workaround.

- [ ] **Test microphone capture.** Speaker playback works but mic input is untested. Need to find TX capture mixer path (AMIC1/AMIC3 via `MIC BIAS Internal1`), test with `arecord`. Check stock `mixer_paths.xml` for capture route. Blocker for walkie-talkie use case.

- [ ] **Test with SIM card inserted.** Modem RF works (sees networks) but NAS status is `limited` (no SIM). BAM DMUX A2_POWER_CONTROL may require PS-attached state. Insert prepaid SIM → check if A2 activates → if yes, rmnet interfaces should come up.

- [ ] **Suspend-to-RAM.** `CONFIG_SUSPEND=y` but untested. Separate from cpuidle/lpm-levels. Try `echo mem > /sys/power/state`. Important for battery life on a portable device.

- [ ] **Bluetooth.** WCNSS PIL is up (WiFi works). BT over SMD should be reachable — check for `btqcomsmd` or hciattach path. Nice-to-have for headset/PTT accessories.

- [x] ~~Fix WCD codec regmap for 4.4 ASoC cache API~~ Added regmap wrapper (REGCACHE_FLAT) that delegates to existing SPMI/AHB read/write. Sound card `msm8909-snd-card` registers, WCD codec probes without crash, ALSA devices created. Audio playback needs `alsa-utils` on rootfs + modem online for Q6 DSP.

- [x] ~~**Confirm audio playback end-to-end.**~~ Working! Stock speaker path: `RX2 MIX1 INP1=RX1`, `RDAC2 MUX=RX2`, `HPHR=Switch`, `Ext Spk Switch=On`, DPCM `PRI_MI2S_RX Audio Mixer MultiMedia1=1`. Speaker uses HPHR PA → GPIO36 ext PA (not internal SPK PA). Q6 ACDB calibration missing but non-fatal. Volume control also confirmed working.

- [x] ~~**Wire up volume potentiometer.**~~ Working out of the box — confirmed during audio test.

- [ ] Investigate DIAG_CHAR=y EDL crash — `late_initcall` workaround in place. `module_init` causes PMIC reset (not normal panic). Likely USB subsystem not ready at `device_initcall` level.

## Low Priority — Polish

- [ ] **Change defconfig default CPU governor.** Currently `CPU_FREQ_DEFAULT_GOV_PERFORMANCE` — CPUs locked at 1267 MHz. Switch to `ondemand` or `interactive` in defconfig so the kernel starts scaling immediately, even before userspace acts. Rootfs sets interactive at boot, but the default wastes power during early boot.

- [ ] **Audit DTS for unused enabled peripherals.** Anything left enabled that isn't used (unused I2C/UART/SPI buses, camera/CSI clocks) draws quiescent current. Disable in bq268 DTS overlay.

- [ ] fbtft dirty region inversion at boot — `start_line=127 > end_line=0` at t+7.4s. One-time during early console init. May cause brief visual glitch. Ref: `dmesg-8393406a208b7.log`.

- [x] ~~Prima wlan `MAX_CFG_INI_ITEMS too small, must be at least 519`~~ Bumped 512→640.

- ~~MSS PIL `No pas_id found` warning~~ Won't fix — modem uses `qcom,pil-self-auth` (not PAS), so `pas_id` is unused. Adding a wrong value could break auth. Cosmetic only.

- ~~lpm-levels deep idle (standalone_pc, coordinated pc).~~ Won't fix — stock OEM kernel ships with `lpm_levels.sleep_disabled=1` on cmdline, confirming the vendor couldn't get it working either. Broadcast timer (arch_mem_timer) has 0 interrupts, required for waking CPUs from power collapse. Per-CPU savings are marginal (6-18 mW); only L2 PC is meaningful (73 mW) but hardest to get right. `qcom,lpm-wa-skip-l2-spm` workaround in DTS confirms known silicon errata. WFI-only idle is fine.

- ~~Broadcast timer (arch_mem_timer).~~ Won't fix — see lpm-levels above. Selected as broadcast device in oneshot mode but never fires. Root cause likely silicon/TZ limitation on this MSM8909 variant. Not worth debugging given OEM also gave up.

## Future — Large Efforts

- [ ] **Catch up with upstream 4.4.x stable releases.** Our base is CAF `kernel.lnx.4.4` (4.4.21). Upstream 4.4.x LTS has hundreds of stable patches (security, driver fixes, core fixes). Need to assess: merge strategy (rebase vs cherry-pick), conflict surface with our CAF-specific code, and whether any stable patches fix known issues. Big effort — needs planning before starting.

- ~~eMMC missing regulator bindings — `No vmmc regulator found` / `No vqmmc regulator found`.~~ Won't fix — CAF sdhci-msm uses its own `vdd-supply`/`vdd-io-supply` path (set in mtp.dtsi, working). The `vmmc`/`vqmmc` messages come from the generic SDHCI core's separate lookup; adding them would cause double regulator management. Cosmetic only.

- [x] ~~CONFIG_KEYBOARD_MATRIX=y to fix gpio-keys~~ Added to defconfig, verified in output/.config.

- [x] ~~screen blanking~~ Removed `consoleblank=0` from cmdline in justfile. fbcon default 10-min blank timer now works (draws black). Backlight stays on (PM8909 MPP4 current sink, needs qpnp-leds driver for proper control — not yet ported).

- [x] ~~Port qpnp-leds for LCD backlight control~~ Enabled `CONFIG_LEDS_QPNP=y`. DTS already correct via MTP DTSI include chain (MPP4 current sink, 20mA, `bkl-trigger`). Confirmed: `/sys/class/leds/lcd-bl/` present at boot. Also registers `button-backlight`, `red`, `green` LEDs.
