# Stable Kernel Upgrade: 4.4.21 → 4.4.302

## Progress

| Target | Built | Booted | Result |
|--------|-------|--------|--------|
| 4.4.21 | `8954c89a355d` | Yes | **Flashed to eMMC** — this is the fallback on normal reboot |
| 4.4.50 | `0046d2e1791e` | Yes | Boots OK, uname confirms 4.4.50-bq268. WiFi module not deployed (no USB ECM on host). |
| 4.4.75 | `e7a933b099c5` | Yes | Boots ok. need to scp wifi module while in 4.4.21 |
| 4.4.100 | `75690d14ff3a` | Yes | Fixed: USB gadget composite unbind NULL deref. Boots + ECM works. |
| 4.4.150 | `27651e70b936` | | Same composite bug present, needs rebuild with fix |
| 4.4.200 | `f8d7e1a42f97` | | Same composite bug present, needs rebuild with fix |
| 4.4.302 | `e46256c2192f` | Yes | **All services OK**, WiFi+SSH, battery 21%. Final EOL kernel working. |

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

## Workflow

**Flashed kernel:** `output/boot-8954c89a355d.img` (4.4.21) is permanently flashed to the eMMC boot partition. A normal reboot always returns to this known-good kernel. New kernels are tested via `fastboot boot` (RAM, not flashed) until validated.

**User availability:** The user may not be available during the porting loop. If the device is unreachable (hang, crash, powered off), **skip boot-testing and keep building**. Record the boot image filename in the progress table. When the user returns, we catch up: flash the latest good image, or bisect through saved images if something broke.

Each step follows the same cycle:

```sh
# 1. Find the stable tag commit in our history
git log --oneline --all --grep='Linux 4.4.50' | grep -v rt | head -1
# e.g.: abc1234 Linux 4.4.50

# 2. Merge it
git merge abc1234 -m "Merge Linux 4.4.50 stable"
# Fix any conflicts, then: git add -u && git commit

# 3. Verify SUBLEVEL in Makefile matches the target
head -4 Makefile
# If SUBLEVEL wasn't updated by the merge (CAF divergence), fix it manually

# 4. Build
just bootimg
# Boot image saved as output/boot-<commit>.img automatically

# 5. Update progress table above with the boot image commit hash

# 6. If device is available:
#    a. Deploy WiFi module (must match running kernel version)
#       VER=$(make -s kernelrelease O=output)  # e.g. 4.4.50-bq268
#       /opt/toolchains/.../arm-linux-gnueabihf-strip --strip-unneeded \
#         -o /tmp/wlan.ko output/drivers/staging/prima/wlan.ko
#       ssh bq268 "mkdir -p /lib/modules/$VER"
#       scp /tmp/wlan.ko root@bq268:/lib/modules/$VER/wlan.ko
#    b. Reboot and boot new image
#       just dev-reboot && just boot
#    c. Wait ~150s, then check
#       ssh bq268 'dmesg | grep -iE "error|oops|panic" | head -20'
#       ssh bq268 'uname -r; cat /sys/class/power_supply/battery/capacity'
#    d. Save dmesg (use short commit hash from the boot image)
#       ssh bq268 dmesg > dmesg-<commit>.log
#    e. Record result in progress table

# 7. If device is NOT available:
#    Continue to the next merge step. Images are saved and can be
#    fastboot-booted retroactively when the device is back.
```

**Recovery:** If the device hangs on a RAM-booted kernel, hold the power button to force reboot — it returns to the flashed 4.4.21 kernel. Then enter fastboot (hold vol-down during boot) and retry or boot a different image.

If `just dev-reboot` can't reach the device (hang/crash), hold the power button to reboot, then hold vol-down during boot to enter fastboot manually. Boot the last known-good image: `fastboot boot output/boot-<good-commit>.img`.

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

## Watchlist: Files That Need Manual Attention

These files caused build failures, boot crashes, or required fixups during our base alignment. Stable merges will likely touch them again.

### Boot-critical (crashes if wrong)

| File | Issue | Our fix | What to watch for |
|------|-------|---------|-------------------|
| `arch/arm/mm/dma-mapping.c` | `__free_from_contiguous` passed `want_vaddr=false` → clears kernel PTE for CMA pages → Oops in `v6_clear_user_highpage` when page re-allocated | Set `want_vaddr=true` | Any change to `__free_from_contiguous` or `__dma_remap` args |
| `drivers/usb/gadget/composite.c` | `disable_l1_for_hs` default flipped to `false` → USB 2.1 LPM advertised → ChipIdea UDC fails to enumerate → no ttyGS0 | Set `disable_l1_for_hs = true` | Any change to this default or the `bcdUSB = 0x0210` path |

### Build-breaking (won't compile if wrong)

| File | Issue | Our fix | What to watch for |
|------|-------|---------|-------------------|
| `drivers/soc/qcom/Makefile` | `smp2p_loopback.o` moved behind `CONFIG_MSM_SMP2P_TEST` but `smp2p.c` references its symbols unconditionally | Keep `smp2p_loopback.o` with `CONFIG_MSM_SMP2P` | Any Makefile reorganization of SMP2P objects |
| `drivers/staging/prima/.../wlan_hdd_main.c` | `cfg80211_connect_bss()` gains/loses `timeout_reason` param; `NL80211_TIMEOUT_UNSPECIFIED` may appear/disappear | Drop the extra arg for our base | Any `cfg80211_connect_bss` signature change in `include/net/cfg80211.h` |
| `drivers/staging/prima/.../wlan_hdd_assoc.c` | Misleading indentation in `hdd_copy_ht_caps` (for-loop scope) and `hdd_copy_vht_caps` (missing braces) triggers `-Werror` | Fixed indentation and added braces | Prima is frozen — only breaks if GCC warnings change |
| `include/uapi/linux/nl80211.h` | `NL80211_ATTR_TIMEOUT_REASON` / `nl80211_timeout_reason` enum added by some stable versions | If added, prima may need the extra arg back | Grep for `TIMEOUT_REASON` after each merge |

### CAF vs upstream conflicts (known hotspots)

| File | CAF modification | Why it conflicts |
|------|-----------------|-----------------|
| `kernel/sched/core.c` | HMP task placement, `core_ctl_check()`, `DEQUEUE_MOVE` | Upstream scheduler fixes touch the same functions |
| `kernel/sched/rt.c` | `on_rq`/`on_list` fields, `task_may_not_preempt()` | Upstream RT fixes assume different struct layout |
| `kernel/locking/osq_lock.c` | We cherry-picked the `smp_wmb()` fix | Upstream may add more barriers or restructure |
| `kernel/locking/rwsem-xadd.c` | Missing `smp_rmb()` in `rwsem_wake()` | Upstream rewrites to `wake_q` API around 4.4.150 |
| `mm/backing-dev.c` | Embedded `backing_dev_info` struct | Upstream converts to refcounted pointer ~4.4.150 |
| `mm/zsmalloc.c` | Simple page-field-based implementation | Upstream adds `struct zspage` abstraction ~4.4.100 |
| `mm/compaction.c` | No `kcompactd` | Upstream adds it ~4.4.100 |
| `drivers/soc/qcom/qdsp6v2/apr.c` | Older refcount semantics, single `service_nb` | Any stable fix touching APR will see different code |
| `drivers/power/supply/qcom/qpnp-linear-charger.c` | `usb_psy` lookup made optional (no USB PSY on 4.4) | Not upstream — our local driver, won't conflict with stable |
