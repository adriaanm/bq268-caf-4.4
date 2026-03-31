# Rebase: CAF msm-4.4 Base Alignment

## Current State

The `bq268` branch is based on CAF commit `31516ed73500e` from the full `kernel.lnx.4.4` history (4.4.21), with a cherry-picked osq_lock barrier fix (`2dd3d52f9567d`) and ~100 custom commits on top. All hardware is working and boot-tested.

The custom commits were originally developed on a shallow clone of a different CAF msm-4.4 snapshot (also 4.4.21, fetched from codelinaro). To get proper git history and enable future stable merges, we identified the closest-matching commit in the `android-linux-stable/msm-4.4` full history by binary-searching 18,374 commits for minimum `git diff --shortstat`.

## How the Base Was Chosen

| Metric | Current base (`31516ed`) | r42 (abandoned) |
|--------|-------------------------|-----------------|
| Files changed vs original snapshot | **1,184** | 8,868 |
| Lines +/- | +76K / -53K | +664K / -115K |
| SUBLEVEL | 21 | 205 |

Of those 1,184 files, only **~170 are in subsystems we compile** for MSM8909. The rest are DTS for other SoCs, video/GPU, IPA, touchscreen drivers, etc.

The original snapshot was from a **later** CAF tag (more security backports). The current base is from an **earlier** point (simpler, fewer hardening patches). For MSM8909 this is fine — critical fixes are cherry-picked as needed.

## Fixes Required After Rebase

Three issues surfaced during boot testing:

1. **`486583f` fix build errors: SMP2P loopback, prima cfg80211/indentation**
   - `smp2p_loopback.o` split into `CONFIG_MSM_SMP2P_TEST` but `smp2p.c` references mock symbols → moved back
   - `NL80211_TIMEOUT_UNSPECIFIED` and `timeout_reason` param absent → dropped from prima
   - Misleading indentation in prima `hdd_copy_ht_caps`/`hdd_copy_vht_caps` → fixed

2. **`ccad3fb` usb: gadget: disable L1 LPM for HS devices**
   - `disable_l1_for_hs` default flipped to `false` → gadget advertises USB 2.1 LPM → ChipIdea UDC fails to enumerate → ttyGS0 never created
   - Restored `disable_l1_for_hs = true`

3. **`0a17da3` arm: dma: restore kernel linear mapping on CMA free**
   - `__free_from_contiguous()` passes `want_vaddr=false` → clears kernel PTE for CMA pages → when re-allocated, `clear_highpage()` crashes on unmapped VA
   - Restored `want_vaddr=true`

## Subsystem Diff Analysis

The 1,184-file diff between the original snapshot and current base breaks down as follows. Only items relevant to MSM8909 compiled code are listed.

### Kernel Core (`kernel/`)

| Area | Change | Risk |
|------|--------|------|
| `sched/` (core, rt, hmp) | Removes `DEQUEUE_MOVE`/`ENQUEUE_MOVE`, `on_rq`/`on_list` RT fields, `task_may_not_preempt()`, `is_max_capacity_cpu()`. Core_ctl refactored. | **Medium** — homogeneous A7, HMP opts don't help |
| `locking/osq_lock.c` | Missing `smp_wmb()` between MCS lock list writes | **Cherry-picked** `2dd3d52f9567d` to fix |
| `locking/rwsem-xadd.c` | Missing `smp_rmb()` in `rwsem_wake()` | **Medium** — massive rewrite needed to fix, not cherry-pickable |
| `softirq.c` | Removes RT-aware softirq deferral | **Low** |
| `time/timer.c` | Simpler deferrable timer handling | **Low** |
| `futex.c` | Page-lock-based key lookup (simpler, proven) | **Low** |

### Memory Management (`mm/`)

| Area | Change | Risk |
|------|--------|------|
| `backing-dev.c` + `block/` + `fs/` | BDI as embedded struct (not refcounted pointer) | **Medium** — internally consistent, compile-time breakage if mismatched |
| `zsmalloc.c` | Simpler implementation, no compaction | **Medium** — ZRAM works, may fragment over time |
| `compaction.c` | No `kcompactd` daemon | **Low** |

### Qualcomm SoC (`drivers/soc/qcom/`)

| Area | Change | Risk |
|------|--------|------|
| `qdsp6v2/apr.c` | Different refcount accounting, removed bounds check | **Medium** — matches 3.18 behavior |
| `qdsp6v2/audio_notifier.c` | Bug in deregister list iteration | **Medium** — rarely triggered |
| `msm_smem.c` | Less bounds checking | **Medium** |

### Audio (`sound/`)

MSM8909 uses `msm8x16-wcd` (unchanged between bases) and `msm8952.c` (unchanged).

| Area | Change | Risk |
|------|--------|------|
| QDSP6v2 PCM/compress/loopback | `pdata->lock` mutex removed from close/volume paths | **Medium** — potential races, low impact on single-user device |
| `q6asm.c` | Session locking simplified | **Medium** |
| `q6afe.c` | Token validation / payload checks removed | **Medium** |
| `core/timer.c`, `core/pcm_native.c` | ALSA timer refactored, `runtime_lock` removed | **Medium** |

### USB, MMC, Other

| Area | Change | Risk |
|------|--------|------|
| `gadget/composite.c` | L1 LPM default changed | **Fixed** (commit `ccad3fb`) |
| `mm/dma-mapping.c` | CMA free clears kernel mapping | **Fixed** (commit `0a17da3`) |
| `gadget/configfs.c` | Disconnect fires during unbind | **Low** |
| `mmc/core/mmc.c` | `&`→`|` bug in clk_scaling | **Low** — clock scaling not active |
| `firmware_class.c` | Adds `/firmware/image` search path | **Positive** |

### Items Confirmed Safe

- MSM8909 DTS: unchanged
- msm8x16-wcd / msm8952.c: unchanged
- sdm660_cdc: not compiled
- `refcount.h` / `pmic-voter.h` / `minidump.h`: not needed
- PSCI / IOMMU / DMA coherent changes: dead code on MSM8909

## Roadmap: Incremental Upgrade to 4.4.302

The current base is 4.4.21. Linux 4.4 LTS reached EOL at 4.4.302 (Feb 2022). The goal is to merge upstream stable fixes incrementally.

### Strategy: Merge Linux stable tags directly

The CAF history bundles each stable merge with hundreds of SoC-specific commits (SDM660, IPA, MDSS) irrelevant to MSM8909 (~5,000 files per CAF merge point). Instead, merge the **pure Linux stable tags** directly — each sublevel bump is ~90 files of real upstream fixes.

**Stable tag diff growth (core kernel files vs current HEAD):**

| Tag | Core files changed | Notes |
|-----|-------------------|-------|
| 4.4.21 (current) | 635 (CAF delta) | Baseline — CAF patches in core kernel |
| 4.4.75 | 1,110 | |
| 4.4.115 | 1,391 | |
| 4.4.155 | 1,666 | |
| 4.4.248 | 2,286 | |
| 4.4.302 (EOL) | 2,442 | |

The 635-file baseline is CAF-specific code in `kernel/`, `mm/`, etc. that upstream doesn't have. These create merge conflicts at known locations (scheduler HMP, CAF locking, timer changes).

### Recommended steps

1. **Merge in chunks of ~25 sublevels**: `git merge <4.4.50 tag>`, build, test, fix conflicts, repeat
2. **Skip Spectre v2** — Cortex-A7 is not vulnerable; mitigations are dead code that adds complexity
3. **Skip BDI refcount change** — embedded struct works; pointer approach is for hot-unplug
4. **Known breaking changes** at each step:
   - ~4.4.100: zsmalloc rewrite, kcompactd
   - ~4.4.150: BDI pointer conversion, scheduler DEQUEUE_MOVE
   - ~4.4.200: rwsem wake_q rewrite, refcount.h
5. **Priority CVE areas**: ext4 (rootfs), USB (gadget/host), networking (WiFi/modem), crypto (WPA)
