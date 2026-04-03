# Tasks

## ~~High Priority — Modem Bringup~~ COMPLETE

Modem fully working: rmt_storage, PPP over SMD data path, AT commands, RF/network scan. See CLAUDE.md for architecture decisions (PPP over SMD, not BAM DMUX).

<details><summary>Completed items</summary>

- [x] **~~Disable CONFIG_ANDROID_PARANOID_NETWORK~~** Set `CONFIG_ANDROID_PARANOID_NETWORK=n` in defconfig. Verified in output/.config.
- [x] **~~Fix hyp_assign_phys failure for rmtfs shared memory~~** — Non-fatal. MSM8909 TZ doesn't implement `MEM_PROT_ASSIGN_ID` (0x16). No fix needed.
- [x] **~~Write/port rmt_storage daemon for Alpine.~~** Done in `~/bq268-alpine/tools/rmt_storage.c`.
- [x] **~~Test modem with rmt_storage running.~~** Modem fully initializes: APR audio, DIAG, DATA channels all working.
- [x] ~~**BAM DMUX data path.**~~ Won't fix — MSM8909 modem uses PPP over SMD, not BAM DMUX.
- [x] **~~Port `msm_rmnet_bam.c` from 3.18.~~** Done (unused — PPP path used instead).

</details>

## High Priority — Stability

- [ ] **Spontaneous reboot during fast fbcon output.** Crash narrows to rapid framebuffer writes (fbcon scrolling dmesg is enough — wata not required). PMIC Hard Reset, no panic/watchdog. **Root cause analysis (2026-04-03):** Display is fbtft (`fb_st7735r`) over SPI5 BAM DMA, not MDP3. `spi_qsd.c` ignored `spi_message.is_dma_mapped` flag — unconditionally called `dma_map_single()` on fbtft's pre-mapped coherent DMA buffer. **Fix applied:** `spi_qsd.c` now respects `is_dma_mapped`, skipping redundant map/unmap. On MSM8909 (non-highmem), the double-mapping was coincidentally harmless (same DMA address), so this fix alone may not resolve the crash. **Full analysis and test plan in `hard_crash.md`.** **Next steps:** (a) Test with fix applied. (b) If still crashes, try FIFO mode (remove `qcom,use-bam` from SPI5 DTS). (c) Try `fbtft.fps=5` to reduce SPI bus utilization. (d) Check pstore after crash. (e) Investigate `CONFIG_QCOM_BUS_SCALING` boot crash.

## Normal Priority — Modem & Diagnostics

- [ ] **Get modem DIAG logs working.** Tool: `tools/diag_read.c`. Build: `just diag-build`. Deploy: `just diag-deploy`. **Partially working:** /dev/diag opens, SWITCH_LOGGING to MEMORY_DEVICE_MODE succeeds, reader thread (pthread) receives mask updates (MSG/EVENT/LOG), SET_ALL_MSG_MASK command sent and propagated to modem. **Not working yet:** No F3 messages arrive — modem DIAG DATA SMD channel (ch9) shows zero traffic in both directions. Modem CNTL channel has unread data (APPS RDPTR=0 vs MDMSW WRPTR=0x1B6B). **Known issues:** (1) DIAG session cleanup on close is broken — stale `md_session_mask` blocks subsequent runs, requires reboot. (2) `USER_SPACE_RAW_DATA_TYPE` write path blocks if `in_busy_pktdata=1` — solved via pthread reader thread. (3) HDLC toggle ioctl causes D-state (kernel mutex contention in `diag_update_md_clients`) — disabled for now. **Next steps:** (a) Investigate why modem CNTL data isn't fully consumed by APPS, (b) try per-SSID mask (SET_MSG_MASK) instead of SET_ALL, (c) consider USB DIAG gadget approach as alternative to /dev/diag.

## Normal Priority — Audio & Hardware

- [x] ~~**Port qpnp-linear-charger from 3.18.**~~ Done. Charger probes, battery PSY registered, charging works. Internal USB PSY added with 500mA default (no BC1.2 detection yet).

- [x] ~~**BC1.2 USB charger type detection.**~~ Done. LBC's USBIN_VALID IRQ triggers the msm_otg ULPI-based BC1.2 state machine. Detects SDP (100mA→500mA after enum) / CDP (1500mA) / DCP (1500mA). LBC internal USB PSY accepts `set_property(CURRENT_MAX)` from the PHY driver. Confirmed working: SDP detected when connected to PC, current ramps 100→500mA after gadget enumeration.

- [x] ~~**Port qpnp-vm-bms from 3.18.**~~ Already present and probing in 4.4. Fixed two issues: (1) stale shutdown OCV register caused 0% SOC — added `qcom,ignore-shutdown-soc` to DTS. (2) `monitor_soc_work` stopped rescheduling before `voltage_soc_timeout_work` flipped to voltage-based mode — restart it from the timeout. Now reports correct SOC (74% at 4.01V charging).

- [x] ~~**Test microphone capture.**~~ Working. TX capture uses TERT_MI2S_TX (not PRI_MI2S_TX — machine driver routes RX via Primary, TX via Tertiary MI2S). Mixer path: `MultiMedia1 Mixer TERT_MI2S_TX=1`, `DEC1 MUX=ADC1`, `ADC1 Volume=8`, `DEC1 Volume=104`. Record: `arecord -D hw:0,0 -f S16_LE -r 48000 -c 1`. Handset mic (AMIC1) confirmed working with loopback test.

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

## Low Priority — CVE Backports (post-4.4.302 EOL)

Kernel is 4.4.302 (EOL Feb 2022). These CVEs were disclosed after EOL and affect our version. Risk is low for a walkie-talkie on trusted networks, but worth tracking. Many high-profile CVEs (nf_tables, net/sched, Bluetooth, ALSA USB, Dirty Pipe) are **not exploitable** because the relevant subsystems are disabled in our config.

### Confirmed exploitable on this platform

| CVE | Subsystem | CVSS | Vector | Assessment |
|-----|-----------|------|--------|------------|
| CVE-2024-49883 | ext4 `ext4_ext_insert_extent` UAF | 7.8 | Local — path reallocation in `ext4_ext_create_new_leaf` leaves stale pointer | Highest priority. ext4 is rootfs. Triggered by normal filesystem operations, not just malicious images. Patch available in stable trees (5.10.227+). |
| CVE-2022-25258 | USB gadget composite OS descriptor validation | 4.6 | Physical USB — crafted control transfer to gadget ep0 | Requires physical USB access. OS descriptor handling is compiled in (libcomposite built-in). Medium risk since device has USB exposed for serial/ECM. |
| CVE-2021-39685 | USB gadget ep0 buffer overflow (65KB read/write) | 7.8 | Physical USB — wLength > 4096 in control transfer | Core composite.c buffer size issue. However, the specifically vulnerable functions (rndis, hid, uac1, uac2) are NOT compiled in. Residual risk in shared ep0 path. |
| CVE-2022-1184 | ext4 `dx_insert_block` UAF | 5.5 | Local — corrupted ext4 filesystem triggers crash | DoS only. Requires mounting malicious ext4 image. Low risk on eMMC-only device. |
| CVE-2023-2513 | ext4 `ext4_xattr_set_entry` UAF | 6.7 | Local — requires CAP_SYS_ADMIN to manipulate xattrs | Requires root. Low risk since attacker with root already owns the device. |

### Not exploitable (disabled subsystems)

These affect 4.4.x per NVD but the vulnerable code is not compiled in our config:

| CVE | Subsystem | CVSS | Why not exploitable |
|-----|-----------|------|---------------------|
| CVE-2024-1086 | nf_tables | 7.8 | `CONFIG_NETFILTER` not set. Actively exploited in ransomware but irrelevant here. |
| CVE-2023-1829 | tcindex (net/sched) | 7.8 | `CONFIG_NET_SCHED` not set |
| CVE-2023-4623 | sch_hfsc (net/sched) | 7.8 | `CONFIG_NET_SCHED` not set |
| CVE-2023-6932 | IPv4 IGMP | 7.0 | `CONFIG_IP_MULTICAST` not set |
| CVE-2024-53197 | USB audio ALSA | 7.8 | `CONFIG_SND_USB_AUDIO` not set. CISA KEV actively exploited. |
| CVE-2024-53150 | USB audio ALSA | 7.8 | `CONFIG_SND_USB_AUDIO` not set. CISA KEV actively exploited. |
| CVE-2022-47929 | net/sched sch_api | 5.5 | `CONFIG_NET_SCHED` not set |

### Not affected (version range excludes 4.4.x)

| CVE | Min version | Description |
|-----|-------------|-------------|
| CVE-2022-0847 (Dirty Pipe) | 5.8+ | Not present in 4.4 |
| CVE-2022-41674/42719/42720 (WiFi RCE) | 5.1+ | MBSSID parsing not in 4.4 mac80211 |
| CVE-2022-0185 | 5.1+ | legacy_parse_param not in 4.4 |
| CVE-2023-0461 | 4.13+ | TLS/ULP subsystem not in 4.4 |
| CVE-2023-0266 (ALSA PCM) | 4.14+ | Not in 4.4 |
| CVE-2022-4378 (sysctl stack overflow) | 4.9+ | Not in 4.4 |
| CVE-2024-36904 (TCP UAF) | 4.16+ | Not in 4.4 |
| CVE-2023-3812 (tun/tap OOB) | 4.15+ | Not in 4.4 |
| CVE-2022-2588 (cls_route UAF) | 4.9+ | Not in 4.4 |
| CVE-2022-47939 (ksmbd RCE) | 5.15+ | ksmbd doesn't exist in 4.4 |
| CVE-2023-2156 (IPv6 RPL DoS) | 5.7+ | RPL not in 4.4 |

### Userspace note

CVE-2023-52160 — wpa_supplicant through 2.10 allows PEAP authentication bypass. Not a kernel CVE but relevant to WiFi. Fixed in Alpine's wpa_supplicant 2.10-r11. Check rootfs version if connecting to Enterprise WPA networks.

## Future — Large Efforts

- [x] ~~**Catch up with upstream 4.4.x stable releases.**~~ Done — merged 4.4.21 → 4.4.302 (EOL). See `stable-upgrade-4.4.md`. Our base is CAF `kernel.lnx.4.4` (4.4.21). Upstream 4.4.x LTS has hundreds of stable patches (security, driver fixes, core fixes). Need to assess: merge strategy (rebase vs cherry-pick), conflict surface with our CAF-specific code, and whether any stable patches fix known issues. Big effort — needs planning before starting.

- ~~eMMC missing regulator bindings — `No vmmc regulator found` / `No vqmmc regulator found`.~~ Won't fix — CAF sdhci-msm uses its own `vdd-supply`/`vdd-io-supply` path (set in mtp.dtsi, working). The `vmmc`/`vqmmc` messages come from the generic SDHCI core's separate lookup; adding them would cause double regulator management. Cosmetic only.

- [x] ~~CONFIG_KEYBOARD_MATRIX=y to fix gpio-keys~~ Added to defconfig, verified in output/.config.

- [x] ~~screen blanking~~ Removed `consoleblank=0` from cmdline in justfile. fbcon default 10-min blank timer now works (draws black). Backlight stays on (PM8909 MPP4 current sink, needs qpnp-leds driver for proper control — not yet ported).

- [x] ~~Port qpnp-leds for LCD backlight control~~ Enabled `CONFIG_LEDS_QPNP=y`. DTS already correct via MTP DTSI include chain (MPP4 current sink, 20mA, `bkl-trigger`). Confirmed: `/sys/class/leds/lcd-bl/` present at boot. Also registers `button-backlight`, `red`, `green` LEDs.
