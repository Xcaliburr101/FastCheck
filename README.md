# FastCheck

**FastCheck** is a Windows PowerShell script that prints a structured hardware and system report to the console. It is aimed at anyone who wants a quick read on device identity, key components, storage headroom, battery health (on laptops), and whether Windows reports any misconfigured or failing plug-and-play devices.

## Compatiblity

This script is aimed at **Windows Powershell** not to be confused with **Powershell**. This is because a newly installed laptop can immidiatly run this script. Windows powershell is shipped with every windows installation and is currently on version **5.1**. This is the older and less sophisticated version of **Powershell 7** which is not installed by default. It will work just fine if you have powershell 7 installed, but for compatibility reasons this script is made for Windows powershell 5.1.


## How to run

From the repository folder:

```powershell
.\FastCheck.ps1
```
or 
Run the precompiled binary from the releases: ```FastCheck.exe``` 

To run with full privileges (right-click EXE, **Run as administrator**, then execute the same command).

## Normal run versus run as administrator

### Normal run (fastest)

Without elevation, the script avoids operations that need administrator rights. 
Sections that depend on elevation show a short note that you must run as admin to check them (for example **Secure Boot** and **BitLocker**).

Use this mode when you want the quickest pass with minimal friction and no UAC prompt.

### Run as administrator (most comprehensive)

With elevation, the script can:

- Report **Secure Boot** status via `Confirm-SecureBootUEFI`.
- Inspect **BitLocker** on the `C:` volume with `Get-BitLockerVolume`.
- Inspect SSD health


**Important:** If BitLocker is not fully decrypted on `C:`, the script attempts to **disable BitLocker** on that volume (`Disable-BitLocker`). If you rely on full-disk encryption, review that behavior before running elevated, or run the normal (non-admin) mode if you only want a read-only style report.

## What the report covers (summary)

| Area | Typical content |
|------|-----------------|
| System and OS | Manufacturer, model, Windows caption and build, BIOS serial |
| Licensing | Product key from firmware OA3 or registry fallback |
| CPU / BIOS | Processor name, core counts, BIOS identification string |
| CPU temperature | Highest reported thermal zone temperature (or not reported) |
| Secure Boot / BitLocker | Only fully populated when elevated (BitLocker may trigger decryption on `C:`) |
| Graphics | Physical GPUs matching common vendor patterns; driver version, resolution, reported VRAM |
| Display | Approximate panel size from WMI monitor data when reported |
| Memory | Per-DIMM capacity, speed, slot, part number |
| External management | Autopilot tenant/enrollment lock indicators from registry when present |
| Storage | Local SSD inventory, health/operational status, and allocation usage |
| Storage reliability (admin) | SSD reliability counters (temperature, power-on hours, write errors, wear) when supported |
| Battery | Charge level; health percentage from WMI or `powercfg /batteryreport` XML if WMI is insufficient |
| Battery voltage | Current vs design voltage check with tolerance-based warning |
| Network test | Basic connectivity probe and roundtrip time to `www.google.com` |
| Device health | PnP entities with configuration error codes (with short descriptions for common codes) |
| Vendor software check | HP software detection on non-HP systems |
| Software health | App package status, pending winget upgrades, pending Windows security/driver updates, crash dump count |

## Limitations

- This is a **snapshot** tool: it reflects what Windows reports at run time, not a full stress test or long-term reliability study.
- Some values (GPU VRAM, monitor size, battery health) can be missing or approximate depending on drivers and firmware.
- Elevated runs have side effects on BitLocker
