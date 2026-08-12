---
name: tia-hardware
description: Create and inspect TIA Portal hardware/device layout via Openness - add CPU stations (New-TiaDevice), plug I/O and communication modules into rack slots (Add-TiaModule / PlugNew), and read an existing rack (Get-TiaModule). Use for device/station/rack/module/slot/MLFB/order-number tasks, or building a hardware layout from a modules spreadsheet. Assumes the tia-openness skill for connection.
---

# TIA hardware / device layout automation

Companion to `tia-openness` (connection basics). This covers building the physical
device configuration: stations, CPUs, and rack modules.

## Cmdlets

| Task | Cmdlet |
|---|---|
| List stations | `Get-TiaDeviceList` |
| Add a CPU station | `New-TiaDevice -TypeIdentifier 'OrderNumber:<MLFB>/<FW>' -Name PLC_1` |
| Read rack modules (+ slots + MLFBs) | `Get-TiaModule [-DeviceName PLC_1]` |
| Plug a module | `Add-TiaModule -DeviceName PLC_1 -Slot 2 -OrderNumber '6ES7 521-1BL00-0AB0/V2.1' -Name DI_16` |

## Order numbers (MLFB) are catalog-specific - discover them

`New-TiaDevice` / `Add-TiaModule` need type identifiers that exist in **your** installed
hardware catalog. The reliable way to get valid ones: read an existing station.

```powershell
Connect-TiaPortal
Get-TiaModule -DeviceName PLC_1 | Format-Table Slot, Name, OrderNumber
```

Copy the exact `OrderNumber:...` strings into your `modules` spreadsheet. A bare
`6ES7 ...` is auto-prefixed with `OrderNumber:` by `Add-TiaModule`. **The firmware
suffix (`/V2.1`) is required** - the bare MLFB without it is rejected.

Order numbers verified to plug on this machine's catalog (S7-1500, next to a 515F CPU):
`6ES7 521-1BH00-0AB0/V2.1` (DI-16), `6ES7 521-1BL00-0AB0/V2.1` (DI-32),
`6ES7 531-7KF00-0AB0/V2.0` (AI-8), `6ES7 532-5HD00-0AB0/V2.0` (AQ-4). The `522` DQ
variants tried were not installed - always confirm against your own catalog.

## How Add-TiaModule works

It searches the device's rack objects for one whose `CanPlugNew(typeId, name, slot)`
returns true, then calls `PlugNew`. If nothing accepts it, the MLFB is wrong for your
catalog, the slot is occupied, or the module is incompatible with the rack - use
`Get-TiaModule` on a working station to find valid parts and slots.

## From a spreadsheet (Phase 1)

A `modules` CSV drives the rack layout in the declarative build:

```
Slot,OrderNumber,Name,Comment
2,6ES7 521-1BL00-0AB0/V2.1,DI_16x24VDC,digital input
3,6ES7 522-1BL01-0AB0/V2.1,DQ_16x24VDC,digital output
4,6ES7 531-7KF00-0AB0/V2.0,AI_8xU_I,analog input
```

Referenced from the manifest per PLC:

```yaml
plcs:
  - name: PLC_1
    orderNumber: "OrderNumber:6ES7 515-2FM02-0AB0/V2.9"
    modules: [ data/PLC_1.modules.csv ]
```

`Invoke-TiaBuildFromSpec` adds the CPU, then plugs each module. Validate first with
`Test-TiaSpec` (checks slots are unique integers and order numbers/names present).

## Notes

- Do device/module writes in a scratch project or your own `-New` instance, not a
  human's live session.
- Module addressing (I/O address per module) beyond default is a future extension;
  for now modules take their default addresses.
