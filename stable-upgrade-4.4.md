# Stable Kernel Upgrade: 4.4.21 → 4.4.302

## Goal

Merge upstream Linux 4.4.x stable fixes into our CAF-based kernel. We're at 4.4.21; the 4.4 LTS series reached EOL at 4.4.302 (Feb 2022). That's 281 sublevel bumps of security and bug fixes.

## Strategy: Merge Linux stable tags directly

Our tree is CAF `kernel.lnx.4.4` — it has thousands of Qualcomm SoC-specific files that upstream doesn't. The CAF history bundles each stable merge with hundreds of irrelevant SoC commits (SDM660, IPA, MDSS), dragging in ~5,000 files per step.

Instead, merge the **pure Linux stable tags** (`Linux 4.4.X` commits in our history). Each sublevel bump is ~90 files / ~900 lines of real fixes — ext4, networking, USB, crypto, etc. — without CAF noise.

## Conflict Surface

Our CAF base modifies ~635 core kernel files that upstream stable also touches (scheduler HMP, CAF locking, timer, mm). These are the merge conflict hotspots. They're in known locations and the CAF changes are well-understood.

**Stable tag diff growth (core kernel files vs current HEAD):**

| Target | Core files to merge | Cumulative stable fixes |
|--------|-------------------|------------------------|
| 4.4.21 (current) | — | — |
| 4.4.50 | ~800 | ~2,000 |
| 4.4.75 | 1,110 | ~3,000 |
| 4.4.115 | 1,391 | ~5,000 |
| 4.4.155 | 1,666 | ~7,000 |
| 4.4.248 | 2,286 | ~12,000 |
| 4.4.302 (EOL) | 2,442 | ~14,000 |

## Plan

Merge in chunks of ~25 sublevels. At each step: merge, build, boot-test, fix conflicts.

### Step 1: 4.4.21 → 4.4.50

Low-risk warmup. Mostly driver fixes, networking, filesystem hardening. No major structural changes.

### Step 2: 4.4.50 → 4.4.75

Still incremental. Futex changes land here but we're already on the simpler (page-lock) side.

### Step 3: 4.4.75 → 4.4.100

**Watch:** zsmalloc rewrite, kcompactd daemon added. These are mm/ structural changes that will conflict with CAF's mm/ patches.

### Step 4: 4.4.100 → 4.4.150

**Watch:** BDI refcount conversion (`backing_dev_info` embedded → pointer). Coordinated change across `mm/`, `block/`, `fs/`. Currently we have the embedded-struct version; the pointer version touches many files. Consider skipping this (embedded works fine) or taking it as a dedicated step.

**Watch:** Scheduler `DEQUEUE_MOVE`/`ENQUEUE_MOVE` flags added. Will conflict with CAF scheduler.

### Step 5: 4.4.150 → 4.4.200

**Watch:** rwsem rewrite (wake_q API). Large structural change, will conflict with CAF locking code.

**Watch:** `refcount.h` added. Not needed by MSM8909-compiled code currently, but other stable patches may start depending on it.

### Step 6: 4.4.200 → 4.4.302

Final push to EOL. Mostly incremental security fixes by this point.

## What to Skip

- **Spectre v2 mitigations** — Cortex-A7 is not affected (no speculative branch prediction). The mitigations add ~10 files of ARM assembly/C complexity with zero security benefit on this CPU. Accept the patches if they apply cleanly; revert if they cause conflicts.

- **BDI refcount conversion** — The embedded-struct approach works. The pointer approach was added for block device hot-unplug correctness that doesn't apply to our eMMC-only device. If this creates too many conflicts, skip it.

## Priority CVE Areas

Focus merge conflict resolution effort on:
- **ext4** — rootfs integrity
- **USB** — gadget/host attack surface
- **networking** (TCP/IP, WiFi cfg80211) — exposed to network
- **crypto** — WPA, module signatures

## Fixes Already Applied

Three issues found during the base alignment that may resurface during stable merges:

1. **CMA free must restore kernel mapping** (`arch/arm/mm/dma-mapping.c`) — `__free_from_contiguous` `want_vaddr` must be `true`, otherwise freed CMA pages crash when re-allocated. Upstream stable may re-introduce the `false` value.

2. **USB gadget L1 LPM must be disabled for HS** (`drivers/usb/gadget/composite.c`) — `disable_l1_for_hs` must default to `true` on ChipIdea UDC, otherwise gadget fails to enumerate.

3. **Prima `cfg80211_connect_bss` API** — upstream added `timeout_reason` parameter at some point; prima doesn't use it. Watch for signature changes.
