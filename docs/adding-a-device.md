# Adding a CPU device to a project

A brand-new project has no PLC, so `Get-TiaPlc` returns nothing until you add one.

```powershell
New-TiaDevice -TypeIdentifier 'OrderNumber:6ES7 511-1AK02-0AB0/V2.9' -Name PLC_1
```

## Finding the right TypeIdentifier (MLFB / order number)

The identifier must match a CPU present in **your** installed hardware catalog. Format:

```
OrderNumber:<MLFB>/<firmware version>
```

Examples (confirm against your catalog / TIA version):

| CPU | TypeIdentifier |
|-----|----------------|
| S7-1515F-2 PN (validated on this machine) | `OrderNumber:6ES7 515-2FM02-0AB0/V2.9` |
| S7-1511-1 PN | `OrderNumber:6ES7 511-1AK02-0AB0/V2.9` |
| S7-1516-3 PN/DP | `OrderNumber:6ES7 516-3AN02-0AB0/V2.9` |
| S7-1214C DC/DC/DC | `OrderNumber:6ES7 214-1AG40-0XB0/V4.4` |
| S7-315-2 PN/DP | `OrderNumber:6ES7 315-2EH14-0AB0/V3.2` |

### How to get an exact, guaranteed-valid identifier

Export an existing device (or a device from the user's `PPS_SR_` project) and read
its order number + firmware, or inspect the hardware catalog. The safest route for
automation is to keep a **project template** that already contains the target CPU and
`Open-TiaProject` a copy of it, rather than constructing devices by MLFB string.

## After adding the CPU

```powershell
$plc = Get-TiaPlc | Select-Object -First 1
New-TiaTag  -Plc $plc.PlcSoftware -TagTable IO -Name Start -DataType Bool -Address '%I0.0'
Import-TiaScl -Plc $plc.PlcSoftware -Path .\templates\Scale.scl
Invoke-TiaCompile -Plc $plc.PlcSoftware
```
