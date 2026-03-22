# Tasks

## High Priority — Modem Bringup

- [ ] **Fix hyp_assign_phys failure for rmtfs shared memory** (0x87c00000, 917504 bytes). Returns -5. Compare `sharedmem_qmi.c` between 3.18 and 4.4 — 3.18 may not call `hyp_assign`. Skip or guard on MSM8909.

- [ ] **Write/port rmt_storage daemon for Alpine.** Serves modem EFS via `/dev/uio0` (rmtfs shared mem). Partitions: modemst1=p26, modemst2=p27, fsg=p3, fsc=p29. Check postmarketOS/Linaro `rmtfs` as starting point. Stock binary at `~/bq268-lineage/vendor/udotech/udosmart/proprietary/vendor/bin/rmt_storage`.

- [ ] **Test modem with rmt_storage running.** Expect modem to progress past watchdog stall, create DIAG/DATA/APR channels, set SMSM_A2_POWER_CONTROL (BAM init), register full QMI services. Stock dmesg shows `apr_tal:Modem Is Up` at t+0.5s and BAM 0x4044000 at t+7s after rmt_storage starts.

## Normal Priority

- [ ] Fix WCD codec regmap for 4.4 ASoC cache API — msm8x16-wcd uses old `.read`/`.write` callbacks, not regmap. `snd_soc_cache_sync()` needs regmap in 4.4. Blocks audio, not modem.

- [ ] Investigate DIAG_CHAR=y EDL crash — `late_initcall` workaround in place. `module_init` causes PMIC reset (not normal panic). Likely USB subsystem not ready at `device_initcall` level.
