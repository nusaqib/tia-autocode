# Feasibility spike: LAD generation, safety (F) blocks, distributed ET200SP

Live results (TIA V19 + Openness, scratch F-CPU) establishing what Openness allows for a
distributed **fail-safe** system programmed in **LAD** - the basis for generating the
SR PPS project (and a future engine capability). Every item below was run end-to-end.

## Summary - what works

| Capability | Result |
|---|---|
| Author **LAD** (FlgNet SimaticML) -> import -> **compile** | ✅ 0 errors/0 warnings |
| Author **F-LAD** F-FB in the safety program -> import -> compile | ✅ 0 errors (1 benign "not called" warning) |
| Export F-FB / F-DB (learn F-block schema) | ✅ works (only the system F-runtime OB `FOB_RTG1` is protected) |
| Create **ET200SP** PROFINET station (IM) via Openness | ✅ `6ES7155-6AU01-0CN0/V4.2` |
| Plug **F-DI/F-DQ/F-RQ/DQ/DI** onto the ET200SP `Rack_0` | ✅ 14/14 BTA modules |
| Assign the station to the CPU's **PROFINET IO system** + compile | ✅ addresses + unique F-dest assigned |
| Set F-DI **1oo2 sensor-evaluation** from code | ❌ not exposed in V19 Openness -> do 1oo2 in software (see below) |
| Read/write other F-DI `Failsafe_*` params (monitoring time, F-addrs, SC-test) | ✅ on the channel sub-item |

**Conclusion:** generating a distributed F-system in LAD via Openness is feasible. No
part of the toolchain is a dead end.

## LAD block schema (proven minimal rung)

A LAD block is `SW.Blocks.FC/FB/OB` with `ProgrammingLanguage = LAD` and a
`CompileUnit` whose `NetworkSource` holds an `FlgNet` (namespace
`.../SW/NetworkSource/FlgNet/v5`). The block `AttributeList` **must** include the full
ordered set (`AutoNumber, Header*, HeaderVersion, Interface, IsIECCheckEnabled,
MemoryLayout, Name, Namespace, Number, ProgrammingLanguage, SetENOAutomatically`) - a
missing `Namespace` etc. is rejected.

Minimal rung = powerrail -> NO contact -> coil:
- Parts: two `Access` (operands) + `Part Name="Contact"` + `Part Name="Coil"`.
  A normally-open contact is just `<Part Name="Contact" UId="..."/>` - **no** `negated`
  TemplateValue (that fails the `TemplateType_TE` enum). Negation would be a
  `<Negated Name="operand"/>` child.
- Wires: `Powerrail -> contact.in`, `operandAccess -> contact.operand`,
  `contact.out -> coil.in`, `operandAccess -> coil.operand` (via `IdentCon`/`NameCon`).

Working files: [`reference/lad/FC_LadTest.xml`](reference/lad/FC_LadTest.xml) (plain LAD),
[`reference/lad/FB_SafeTest.xml`](reference/lad/FB_SafeTest.xml) (F-LAD, safety).

## Safety (F) specifics

- An F-FB is an ordinary `SW.Blocks.FB` with `ProgrammingLanguage = F_LAD` (or `F_FBD`)
  plus `UDABlockProperties` / `UDAEnableTagReadback` attributes. Importing one places it
  in the safety program; the whole-PLC compile includes the safety run-time.
- The system-generated F-run-time OB (`FOB_RTG1`) is export-protected - do not author it;
  author the F-FBs it calls. The F-DB and F main FB export fine.
- Operands in an F-FB rung can be the block's own interface members
  (`Access Scope="LocalVariable"`).

## Distributed ET200SP + F-modules

- Create the station: `project.Devices.CreateWithItem('OrderNumber:6ES7155-6AU01-0CN0/V4.2', name, name)`.
  It yields `Rack_0`, the IM head with a **PROFINET interface**, and a bus adapter.
- Plug peripherals onto `Rack_0` with `PlugNew(orderNumber, name, position)` - **the
  order number needs a firmware version** (`.../0CA0/V1.0`); `CanPlugNew` finds valid
  position/version combos. The engine's `Add-TiaModule` (central-rack oriented) does not
  find the ET200SP rack - distributed plugging needs the `Rack_0`-targeted call above.

## PROFINET IO-system assignment (PROVEN - BTA build, 2026-07-23)

Connect an ET200SP IM to the CPU as an IO device. **Order matters** - the CPU interface
must be on a subnet *before* `CreateIoSystem`:

```powershell
$niT   = [Siemens.Engineering.HW.Features.NetworkInterface]
$cpuNi = <GetService NetworkInterface on CPU 'PROFINET interface_1'>
$imNi  = <GetService NetworkInterface on IM  'PROFINET interface'>
$subnet   = ($cpuNi.Nodes  | Select -First 1).CreateAndConnectToSubnet('PN_BTA')   # 1) subnet FIRST
$ctrl     =  $cpuNi.IoControllers | Select -First 1
$ioSystem = if ($ctrl.IoSystem) { $ctrl.IoSystem } else { $ctrl.CreateIoSystem('PN_BTA') }  # 2)
($imNi.Nodes | Select -First 1).ConnectToSubnet($subnet)                            # 3) IM node
($imNi.IoConnectors | Select -First 1).ConnectToIoSystem($ioSystem)                 # 4) IM -> IO sys
```

After a whole-CPU compile TIA assigns real I/Q addresses and **unique F-destination
addresses** (observed 65534, 65533, ... descending). CPU used: **CPU 1512SP F-1 PN**
`6ES7 512-1SK01-0AB0/V2.9` (ET200SP fail-safe). Each ET200SP **F-DI 8ch HF occupies 7
input bytes**; the 8 safe channel values are byte 0 of the module's range, so a channel
is `%I{base}.{ch}` with `base = 7*(slotIndex)` for consecutive F-DI in slots 1..N.
Working reference: `PPS_SR/source/build_zone_hw.ps1` (builds a full zone: CPU + station +
14 modules + IO-system + compile).

## 1oo2 F-parameters - IMPORTANT Openness limitation (V19)

The F-DI **channel sub-item** exposes a rich `Failsafe_*` set via `GetAttributeInfos()` /
`GetAttribute()` - `Failsafe_FMonitoringtime`, `Failsafe_FSourceAddress`,
`Failsafe_FDestinationAddress`, `Failsafe_FSIL`, per-channel
`Failsafe_ShortCircuitTest_0..7`, `Failsafe_BehaviorAfterChannelFault`,
`Failsafe_DIPSwitchSetting`, etc. **But there is NO sensor-evaluation (1oo1/1oo2) or
discrepancy-time attribute** in the set - firmware 1oo2 cannot be configured from code in
V19. (Earlier the spike assumed these were reachable "on channel sub-items"; the full
57-attribute dump disproves that for `6ES7136-6BA01-0CA0`.)

**Resolution:** do 1oo2 in **software** in the F-LAD safety FB - wire both device contacts
to one F-DI module (retaining the same-module diagnostic advantage), read the two channels
as raw safe Bools, and evaluate equivalence + a discrepancy timer in the F-program. Fully
automatable and certifiable. (Firmware 1oo2, if required, is a manual step in the TIA HW
editor after generation.)

## F-block interface types (gotcha)

Fail-safe block interfaces permit only **elementary** datatypes - a custom UDT is rejected
with *"The type &lt;UDT&gt; is not permitted in the fail-safe block interface."* (and every
`.member` access off it then reports *"Tag not defined"*). Use `Bool`/`Int`/`Word`/`Time`
statics inside the F-FB; keep UDT-structured status in a **standard** (non-F) DB that a
normal FC copies the safe values into for the HMI. Reading standard PLC tags at F-periphery
addresses (F-DI channels) as `Scope="GlobalVariable"` operands inside an F-LAD rung *is*
allowed. Proven: SR PPS `FB_BTA_Safety` = 23 series-contact (software-1oo2) networks +
a zone interlock -> whole-CPU compile **0 errors / 0 warnings**
(`PPS_SR/source/gen_bta_flad.py`).

## Still to fold into the engine (known-doable)

- Fold the proven LAD/F-LAD emission + ET200SP plug + IO-system assignment into
  `TiaOpenness` cmdlets (a LAD-rung builder + `New-TiaIoDevice`) once BTA validates them.
