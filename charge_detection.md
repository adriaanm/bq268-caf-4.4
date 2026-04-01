# USB Charger Type Detection (BC1.2)

## Problem

The qpnp-linear-charger registers an internal USB PSY that defaults to 500mA. This works but is suboptimal — dedicated chargers (DCP) can supply 1500mA, and we're leaving charge speed on the table.

## Background

BC1.2 (Battery Charging Specification 1.2) defines how a device detects what it's plugged into:

| Type | D+/D- | Current | Detection |
|------|-------|---------|-----------|
| SDP (Standard Downstream Port) | Enumerated by host | 100mA → 500mA after config | Primary detection: comparator output LOW |
| CDP (Charging Downstream Port) | Host + charge | 1500mA | Secondary detection: comparator output LOW |
| DCP (Dedicated Charging Port) | D+/D- shorted | 1500mA | Secondary detection: comparator output HIGH |

## Current State

- **LBC charger** (`qpnp-linear-charger.c`): Registers internal "usb" PSY with hardcoded 500mA. Reads `CURRENT_MAX` from USB PSY to set charge current. No charger type awareness.
- **USB PHY** (`phy-msm-usb.c`): Has full BC1.2 state machine (`msm_chg_detect_work`, lines 845-1143). Detects SDP/CDP/DCP correctly via SNPS 28nm PHY ULPI registers. But `msm_otg_notify_charger()` (line 662) just logs the result — never tells the charger.
- **msm_otg is disabled**: We use ChipIdea UDC + configfs for USB gadget. Enabling full msm_otg would conflict with this setup.

## Plan

Extract the BC1.2 detection logic from `phy-msm-usb.c` into a small standalone driver (~200 lines) that:

1. Probes on the USB PHY DT node (or a new `qcom,usb-chg-detect` node)
2. On VBUS insertion (USBIN_VALID IRQ from LBC, or B_SESS_VLD from PHY):
   - Runs DCD (Data Contact Detection): enable IDP_SRC, poll for D+ contact (up to 600ms)
   - Runs primary detection: enable VDP_SRC + comparator, read result
   - If charger detected, runs secondary detection: VDM_SRC + comparator
3. Updates the LBC's internal USB PSY `current_max`:
   - SDP: 500mA (or 100mA until gadget enumeration)
   - CDP: 1500mA
   - DCP: 1500mA
4. On VBUS removal: reset to 0mA

### ULPI Register Details (SNPS 28nm PHY)

**Control (write to SET=0x85 / CLEAR=0x86):**
- Bit 0: Enable BC comparator
- Bit 1: VDP_SRC (D+ voltage source)
- Bit 2: Rdm_down (D- pull-down for DCD)
- Bit 3: VDM_SRC (D- voltage source)
- Bit 4: IDP_SRC (D+ current source for DCD)

**Status (read from 0x87):**
- Bit 0: Comparator output (primary/secondary detection result)
- Bit 1: DCD complete

### Integration with LBC

The LBC's internal USB PSY needs a `set_property` for `CURRENT_MAX` — but only callable from kernel (not sysfs-writable). The detection driver calls `power_supply_set_property()` on the "usb" PSY after determining charger type. The LBC's existing `qpnp_batt_external_power_changed()` picks up the change and adjusts the hardware charge current.

### Files to Create/Modify

- **New**: `drivers/usb/phy/msm-usb-chg-detect.c` — standalone BC1.2 detection driver
- **Modify**: `qpnp-linear-charger.c` — add kernel-only `set_property` for `CURRENT_MAX` on internal USB PSY
- **Modify**: DTS — add `qcom,usb-chg-detect` node (or reuse existing PHY node)

### Alternative: Reuse msm_otg charger detection only

Instead of a new driver, enable just the charger detection portion of `phy-msm-usb.c` without the full OTG state machine. This is harder to isolate — the BC1.2 code is interleaved with OTG state transitions. A standalone driver is cleaner.

## Constants

From `include/linux/usb/msm_hsusb.h`:
- `IDEV_CHG_MAX` = 1500 mA
- `IUNIT` = 100 mA
- DCD timeout: 600ms (4.4) / 750ms (3.18)
- Primary/secondary detection settle time: 40-50ms
