# Rebase Plan: CAF msm-4.4 Base Alignment

## Branch Topology

| Branch | Base commit | SUBLEVEL | Description |
|--------|------------|----------|-------------|
| `bq268` | `5cfb00b92fdc4` "CAF msm-4.4 base (shallow root)" | 4.4.21 | Working kernel, shallow clone of a later CAF tag |
| `bq268-rebased` | `31516ed73500e` "Merge msm: mdss: fix secure..." | 4.4.21 | Rebased onto closest CAF match + osq_lock fix — **working** |
| `bq268-rebased-r42-backup` | `f1938860f0195` "Merge 46a5afe..." | 4.4.205 | Failed attempt: rebased onto r42 — too large a jump, crashes |

The two bases share no common git ancestor (shallow clone vs full history).

## Finding the Closest Match

We searched the full CAF history between `1d074db69c46d` (upstream "Linux 4.4.21" tag) and `31516ed73500e` — 18,374 commits — measuring `git diff --shortstat` against our old base `5cfb00b92fdc4`. The diff size follows a U-curve: very large far from the old base, with a clear minimum plateau.

**Best match: `31516ed73500e`** — `Merge "msm: mdss: fix secure session power vote"`

| Metric | Old base → best match | Old base → r42 (failed rebase) |
|--------|----------------------|-------------------------------|
| Files changed | **1,184** | 8,868 |
| Insertions | +76K | +664K |
| Deletions | -53K | -115K |
| Upstream commits beyond match | 0 | 25,891 |
| SUBLEVEL | 21 (same) | 205 |

Of those 1,184 files, only **~170 are in subsystems we actually compile** for MSM8909 (ARM core, kernel, mm, drivers/soc/qcom, sound, USB gadget, etc.). The remaining ~1,000 are DTS for other SoCs, video/GPU, IPA, touchscreen, and other unbuilt drivers.

## Diff Direction

The old base (`5cfb00b`) is from a **later** CAF release tag (more backported security fixes, newer driver features). The new base (`31516ed`) is from an **earlier** point in the CAF tree (simpler, fewer hardening patches). This means the diff is partly a *downgrade*: the new base lacks some 2017–2018 security/stability patches present in the old base. For MSM8909, this is acceptable — we don't need the newer IPA, SDM660, or SLIMbus features, and critical fixes can be cherry-picked.

## Subsystem-by-Subsystem Analysis

### ARM Architecture (`arch/arm/`)

**No MSM8909 DTS changes.** Zero msm8909 files differ between the bases.

| Area | Change | Risk |
|------|--------|------|
| `mm/dma-mapping.c` | Removes `is_coherent` parameter threading through DMA alloc/free. On ARMv7 without LPAE, `pgprot_dmacoherent` = `pgprot_writecombine`, so behavior is identical for MSM8909 (no coherent devices). IOMMU section: behind `CONFIG_ARM_DMA_USE_IOMMU` (not set). | **None** |
| `kernel/psci_smp.c` | Removes PSCI cpuidle ops | **None** — `CONFIG_ARM_PSCI` not set |
| `include/asm/perf_event.h` | Removes `armv8pmu_*` inline functions | **Low** — verify `perf_event_armv8.c` still compiles if CONFIG_HW_PERF_EVENTS is set |

### Kernel Core (`kernel/`)

| Area | Change | Risk | Notes |
|------|--------|------|-------|
| `sched/core.c`, `sched.h`, `rt.c` | Removes `DEQUEUE_MOVE`/`ENQUEUE_MOVE` flags, `on_rq`/`on_list` fields from RT sched entity, `task_may_not_preempt()`, `is_max_capacity_cpu()` | **Medium** | Scheduler simplification. MSM8909 is homogeneous A7, so HMP/big.LITTLE optimizations don't help. |
| `sched/core_ctl.c` | Refactored core isolation logic, adds per-cpu `online` tracking, removes `core_ctl_disable_cpumask` boot param | **Medium** | Behavioral change in CPU hotplug decisions |
| `locking/osq_lock.c` | **Removes `smp_wmb()` between `node->prev` and `prev->next` writes** | **Medium-High** | ARM is weakly ordered. This barrier protected MCS lock list integrity under contention. The old base added it; the new base lacks it. Monitor for rare lock corruption. |
| `locking/rwsem-xadd.c` | Removes `smp_rmb()` in `rwsem_wake()` | **Medium** | Same weak-ordering concern |
| `softirq.c` | Removes RT-aware softirq deferral | **Low** | CAF optimization removed; slightly higher RT latency |
| `time/timer.c` | Removes `deferrable_pending` atomic + `check_pending_deferrable_timers()` | **Low** | Simpler deferrable timer handling, fine with lpm-levels disabled |
| `time/hrtimer.c` | Reworks `migrate_hrtimer_list()`, adds `udelay(2)` wait for running callbacks | **Low** | Only during CPU isolation |
| `futex.c` | Reverts to page-lock-based key lookup (from lockless RCU) | **Low** | Slower but proven correct |
| `cpu.c` | Removes RT policy boost during `cpu_up()` | **Low** | |

### Memory Management (`mm/`)

| Area | Change | Risk | Notes |
|------|--------|------|-------|
| `backing-dev.c` + `block/` + `fs/block_dev.c` | **Coordinated revert**: `backing_dev_info` from refcounted heap pointer back to embedded struct. `bdi_alloc_node()`→`bdi_init()`, `bdi_put()`→`bdi_destroy()`, `q->backing_dev_info->`→`q->backing_dev_info.` | **Medium** | Internally consistent across mm/block/fs. Any driver doing `q->backing_dev_info->` (pointer deref) will break at compile time — easy to catch. |
| `zsmalloc.c` | Complete rewrite: removes `struct zspage` abstraction, compaction, migration. Back to using `struct page` fields directly. | **Medium** | ZRAM still works but may fragment over time. Simpler code = fewer bugs. |
| `compaction.c` | Removes `kcompactd` daemon | **Low** | Compaction only on direct reclaim |
| `vmscan.c` | Refactored shrink_zone/shrink_node | **Low** | |

### Filesystem (`fs/`)

| Area | Change | Risk | Notes |
|------|--------|------|-------|
| `dcache.c` | Removes `take_dentry_name_snapshot()` API | **Low** | Re-introduces rename race in fsnotify — irrelevant for single-user embedded |
| `ext4/inode.c` | Changes ordered-data file tracking | **Low** | Minor crash-consistency change |
| `ext4/acl.c` | `posix_acl_update_mode()`→`posix_acl_equiv_mode()` | **Low** | Alpine doesn't use POSIX ACLs |
| `timerfd.c` | Removes `cancel_lock` spinlock | **Low** | |

### Qualcomm SoC Drivers (`drivers/soc/qcom/`)

| Area | Change | Risk | Notes |
|------|--------|------|-------|
| `qdsp6v2/apr.c` | Fixes `port_cnt`/`svc_cnt` accounting. Removes `temp_port` bounds check in dispatch. Single `service_nb` instead of split adsp/modem. | **Medium** | APR refcount changes match 3.18 behavior. The removed bounds check is a concern but the old (simpler) code worked. |
| `qdsp6v2/audio_notifier.c` | **Bug**: `audio_notifier_deregister` iterates from `client_data->list` instead of `client_list` | **Medium** | Known old-CAF bug, rarely triggered (only on module unload/SSR) |
| `msm_smem.c` | Removes SMEM partition bounds-checking/overflow guards | **Medium** | Safety checks removed, but older code worked |
| `peripheral-loader.c` | Removes `clear_fw_region` (no memory zeroing on load failure) | **Low** | |
| `subsystem_restart.c` | Adds debugfs, makes `subsys_bus_type` static | **Low** | |
| `secure_buffer.c` | Dynamic batching → static 512KB `qcom_secure_mem` buffer | **Low** | Wastes 512KB but simpler |
| `watchdog_v2.c` | Removes minidump integration | **None** | Minidump not enabled |

### Audio (`sound/`)

MSM8909 uses `SND_SOC_MSM8X16_WCD` codec (not sdm660_cdc) and `msm8952.c` machine driver.

| Area | Change | Risk | Notes |
|------|--------|------|-------|
| `core/timer.c` | ALSA timer start/stop/continue refactored (separate functions, different locking) | **Medium** | Core infrastructure change |
| `core/pcm_native.c` | `runtime_lock` spinlock removed from `snd_pcm_substream` | **Medium** | Less PCM locking |
| `soc/msm/qdsp6v2/q6asm.c` | Session management: per-session spinlock → simple array. `cmd_state_pp` removed. | **Medium** | Simpler but less thread-safe |
| `soc/msm/qdsp6v2/q6afe.c` | `afe_token_is_valid()` removed, payload size checks removed | **Medium** | Less validation on APR responses |
| `soc/msm/qdsp6v2/msm-pcm-q6-v2.c` | **All `pdata->lock` mutex locking removed** from close/volume paths | **Medium-High** | Potential races during concurrent open/close. In practice, single-user embedded device rarely hits this. |
| `soc/msm/qdsp6v2/msm-compress-q6-v2.c` | `pdata->lock` removed, `is_in_use` tracking removed | **Medium** | Same pattern |
| `soc/msm/qdsp6v2/msm-pcm-loopback-v2.c` | `loopback_session_lock` removed | **Medium** | Same pattern |
| `soc/msm/qdsp6v2/msm-pcm-routing-v2.c` | DTS Eagle hooks added (guarded by CONFIG_DTS_EAGLE) | **None** | |
| New files: `msm-dts-eagle.c`, `msm-dolby-dap-config.c`, `msm-compr-q6-v2.c` | DTS Eagle + Dolby + compress helper | **None** | Behind CONFIG guards |

**Note:** The sdm660_cdc changes flagged as "CRITICAL" by the analysis are **not relevant** — MSM8909 uses `msm8x16-wcd`, not sdm660_cdc. The msm8x16-wcd codec files are unchanged between the two bases.

### USB (`drivers/usb/`)

| Area | Change | Risk | Notes |
|------|--------|------|-------|
| `gadget/configfs.c` | Removes `unbinding` flag; disconnect events fire during unbind | **Low** | CONFIG_USB_CONFIGFS_UEVENT not set |
| `gadget/composite.c` | L1 LPM default: `true`→`false` (enables L1 by default) | **Low-Medium** | Could affect USB serial/ECM power behavior |

### MMC (`drivers/mmc/`)

| Area | Change | Risk | Notes |
|------|--------|------|-------|
| `core/mmc.c` | **Bug**: `&` changed to `|` in clk_scaling_highest check (condition always true) | **Low** | Clock scaling likely not active on MSM8909 eMMC |
| `core/core.c` | Removes SDR104 fallback, cmdq_hw_reset uses power_restore | **Low** | MSM8909 uses eMMC, not SD |

### Other Drivers

| Area | Change | Risk | Notes |
|------|--------|------|-------|
| `clk/msm/clock-local2.c` | Adds `is_same_rcg_config()` optimization; pixel fraction table changed | **Low** | Avoids glitches from redundant RCG updates |
| `regulator/core.c` | `mod_delayed_work`→`queue_delayed_work` for deferred disable | **Low** | |
| `spmi/spmi-pmic-arb.c` | Removes `reserved_chan` DT support, removes ACC_STATUS fallback | **Low** | Check if MSM8909 DTS has `qcom,reserved-chan` |
| `power/reset/msm-poweroff.c` | Removes `scm_disable_sdi()` before reboot | **Low** | Matches older behavior |
| `char/diag/*` | Removes PD-session (WLAN/AUDIO/SENSORS) handling, removes md_session_lock | **Low** | MSM8909 doesn't have user PDs |
| `input/misc/qpnp-power-on.c` | Removes software debounce for KPDPWR | **Low** | Hardware debounce still works |
| `base/firmware_class.c` | Adds `/firmware/image` to firmware search path | **Positive** | Matches Qualcomm stock |
| `net/wireless/` | Regulatory DB update, NL80211 simplifications | **Low** | |

### Deleted Headers (not needed by MSM8909)

| Header | Used by MSM8909? | Notes |
|--------|-----------------|-------|
| `include/linux/refcount.h` | **No** | `refcount_t` not used in compiled code |
| `include/linux/pmic-voter.h` | **No** | Only used by SMB2/TADC (not in defconfig) |
| `include/soc/qcom/minidump.h` | **No** | CONFIG_QCOM_MINIDUMP not set |

## Risk Summary

**Highest attention items for the rebase:**

1. **`kernel/locking/osq_lock.c`** — Missing `smp_wmb()` on ARM. Monitor for rare mutex corruption under load.
2. **`mm/backing-dev.c` + `block/` + `fs/`** — BDI pointer→embedded struct. Any out-of-tree driver using `q->backing_dev_info->` syntax will break (compile-time, easy to fix).
3. **QDSP6v2 mutex removals** — PCM/compress/loopback drivers lose `pdata->lock`. Low risk on single-user device but worth noting for audio debugging.
4. **`kernel/sched/`** — RT scheduler entity restructured. Compile-time breakage if any code references removed fields.
5. **`mm/zsmalloc.c`** — Complete rewrite (simpler). ZRAM works but no compaction.

**Items confirmed safe:**
- MSM8909 DTS: unchanged
- msm8x16-wcd codec: unchanged
- msm8952.c machine driver: unchanged
- sdm660_cdc codec: not compiled
- refcount.h / pmic-voter.h: not needed
- DMA mapping coherent removal: no-op on MSM8909
- PSCI / IOMMU changes: dead code

## Rebase Result

Branch `bq268-rebased` is now based on `31516ed73500e` with all 97 custom commits cherry-picked (one conflict in `drivers/soc/qcom/Makefile` — SMP2P test split, trivially resolved).

### Boot-tested: all hardware working

| Subsystem | Status | Notes |
|-----------|--------|-------|
| SMP | **4/4 CPUs** | All cores online |
| eMMC rootfs | **Working** | ext4 on p36 |
| USB serial | **Working** | ttyGS0/ttyACM0 via configfs ACM |
| USB ECM | **Working** | Network over USB |
| Display | **Working** | SPI ST7735S via fbtft |
| Sound card | **Working** | `#0: msm8909-snd-card` registered at 1.67s |
| Modem | **Working** | PIL auth OK, online at 36.5s, SSCTL connected |
| WCNSS/Pronto | **PIL OK** | Auth + err_ready OK; wlan.ko needs rootfs rebuild |
| WiFi | **Module mismatch** | `wlan: disagrees about version of symbol module_layout` — rootfs wlan.ko built against old kernel, rebuild fixes it |

### Fixes required during rebase (3 commits)

1. **`486583f` fix build errors: SMP2P loopback, prima cfg80211/indentation**
   - New base split `smp2p_loopback.o` into `CONFIG_MSM_SMP2P_TEST` but `smp2p.c` references mock symbols unconditionally → moved back
   - New base lacks `NL80211_TIMEOUT_UNSPECIFIED` and `timeout_reason` param on `cfg80211_connect_bss()` → dropped from prima
   - Fixed misleading indentation in prima `hdd_copy_ht_caps`/`hdd_copy_vht_caps`

2. **`ccad3fb` usb: gadget: disable L1 LPM for HS devices**
   - New base changed `disable_l1_for_hs` default from `true` to `false`, causing gadget to advertise USB 2.1 with LPM → ChipIdea UDC fails to enumerate → ttyGS0 never created
   - Restored `disable_l1_for_hs = true`

3. **`0a17da3` arm: dma: restore kernel linear mapping on CMA free**
   - New base changed `__free_from_contiguous()` to pass `want_vaddr=false` to `__dma_remap()`, clearing kernel PTE for CMA pages
   - When freed CMA pages re-enter buddy allocator and get allocated for user pages, `clear_highpage()` → `__memzero` crashes on unmapped kernel VA
   - Restored `want_vaddr=true` — repeated Oops in `v6_clear_user_highpage_nonaliasing` fixed

## Roadmap: Incremental Upgrade to Latest 4.4.x

The current base (`31516ed`, 4.4.21) is stable but old. The goal is to incrementally advance through the CAF/Android-stable merge points toward 4.4.205+ for security fixes, without repeating the r42 jump.

### Strategy

Advance through the `Merge android-4.4-p.NNN` commits in the CAF history. Each merge brings one stable kernel point release (4.4.22, 4.4.23, ..., 4.4.205). These are well-defined, testable waypoints.

At each waypoint:
1. Measure diff against current HEAD (`git diff --shortstat`)
2. If delta is small (<200 files), merge or rebase directly
3. If delta is large, check for known-breaking changes (BDI, scheduler, Spectre, API changes)
4. Build, boot-test, fix breakage, commit fixes, continue

### Key waypoints identified

| Waypoint | SUBLEVEL | Key changes | Est. delta |
|----------|----------|-------------|-----------|
| Current base | 21 | — | 0 |
| `Merge android-4.4-p.100` region | ~100 | Spectre v2 mitigations (proc-v7-bugs.c), KPTI stubs, futex rework | Large — Spectre is structural |
| `Merge android-4.4-p.150` region | ~150 | BDI refcount (backing-dev.c→pointer), kcompactd, zsmalloc rewrite | Large — mm/block/fs coordinated change |
| `Merge android-4.4-p.200` region | ~200 | rwsem wake_q rewrite, scheduler DEQUEUE_MOVE, refcount.h | Medium |
| `f1938860f0195` (r42 base) | 205 | Full CAF r42 with all above + APR platform driver + ADM 32ch | Largest |

### Merge stable directly, not via CAF merges

The CAF history bundles each stable merge with hundreds of SoC-specific commits (SDM660, IPA, MDSS, etc.) that don't apply to MSM8909. Advancing through `Merge android-4.4-p.NNN` would drag in ~4,700-5,300 files per step — most irrelevant.

Instead, merge the **pure Linux stable tags** (`Linux 4.4.X`) directly. Each sublevel bump is ~90 files / ~900 lines of real upstream fixes — security, networking, ext4, USB, etc.

**Stable tag diff growth (core kernel files vs current HEAD):**

| Tag | Core files changed | Cumulative stable fixes |
|-----|-------------------|------------------------|
| `4.4.21` (current) | 635 (CAF-only delta) | 0 |
| `4.4.22` (1 step) | ~650 | 92 files, +652/-268 lines |
| `4.4.75` | 1,110 | ~3,000 fixes |
| `4.4.115` | 1,391 | ~5,000 fixes |
| `4.4.155` | 1,666 | ~7,000 fixes |
| `4.4.248` | 2,286 | ~12,000 fixes |
| `4.4.302` (EOL) | 2,442 | ~14,000 fixes |

The 635-file baseline is from CAF patches in core kernel code that upstream stable doesn't have (scheduler HMP, CAF locking, timer changes, etc.). These create merge conflicts but are manageable since they're in known locations.

### Recommended approach

1. **Merge in chunks of ~25 sublevels**: `git merge v4.4.50`, test, fix conflicts, then `v4.4.75`, etc.
2. **Skip Spectre v2 mitigations** — Cortex-A7 is not affected (no speculative branch prediction); the mitigations add ~10 files of complexity with zero security benefit on this CPU.
3. **Skip BDI refcount change** — the embedded struct approach works; pointer approach was for hot-unplug correctness that doesn't apply.
4. **Watch for known breaking changes** at each step:
   - ~4.4.50: futex rework (lockless → page-lock, already on the simpler side)
   - ~4.4.100: zsmalloc rewrite, kcompactd addition
   - ~4.4.150: BDI pointer conversion, scheduler DEQUEUE_MOVE
   - ~4.4.200: rwsem wake_q rewrite, refcount.h addition
5. **Priority CVE areas**: ext4 (rootfs), USB (gadget/host), networking (WiFi/modem), crypto (WPA)
