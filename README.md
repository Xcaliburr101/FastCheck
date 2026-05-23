# FastCheck

**FastCheck** is a Windows PowerShell 5.1 WPF diagnostic dashboard. It streams hardware and system health results into section cards as each check finishes, so you are not waiting for the entire run before seeing data.

Diagnostic logic lives in [`FastCheck.Core.ps1`](FastCheck.Core.ps1). The GUI is [`FastCheck.UI.ps1`](FastCheck.UI.ps1). [`FastCheck.ps1`](FastCheck.ps1) is the STA entry point.

## Compatibility

Target runtime is **Windows PowerShell 5.1** with the **.NET Framework** built into Windows (`PresentationFramework`). No .NET 6+ install is required.

## How to run

```powershell
.\FastCheck.ps1
```

Or explicitly with Windows PowerShell 5.1 (recommended from VS Code / Cursor terminals):

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -STA -NoProfile -ExecutionPolicy Bypass -File .\FastCheck.ps1
```

The launcher automatically restarts in **Windows PowerShell 5.1 STA** when needed. If you previously saw exit code **5** (`0x00000005`), that was the editor host being launched instead of `powershell.exe` — this is fixed in the current launcher.

For BitLocker, Secure Boot, and SSD SMART metrics, run PowerShell or the built EXE **as administrator**.

## Scan modes

| Mode | What it does | Typical duration |
|------|----------------|------------------|
| **Quick Scan** | All hardware/OS checks; Appx + crash dumps only for software (skips winget and Windows Update search) | Often under 15 seconds |
| **Full Scan** | Same as Quick, plus winget (25s timeout) and Windows Update pending search (45s timeout) in parallel | Often 30–90 seconds |

Slow operations never block the UI thread. Results appear as **section cards** on the left; a **live log** on the right shows progress, timeouts, and sub-steps (for example `Software: starting winget...`).

## Interface

- **Section cards** — two-column label/value grid per check, color-coded severity (OK / Warning / Error)
- **Live log** — Consolas stream with timestamps
- **Progress bar** — advances per logical section (15 steps)
- **Cancel** — stops remaining sections; cards already completed stay visible
- **Double-click a card** — opens a detail window (separate thread) with full text

### Design

Slate dark theme (`#0F172A` background, `#1E293B` cards, `#38BDF8` accents). Default window size 1280×800.

## Administrator vs normal

| Feature | Normal | Admin |
|---------|--------|-------|
| System, CPU, memory, GPU, network, etc. | Yes | Yes |
| Secure Boot | Admin required note | Full status |
| BitLocker | Admin required note | Full status + confirm before decrypt |
| SSD reliability counters | Not shown | When driver supports SMART |

**BitLocker:** If `C:` is encrypted, a **Yes/No** dialog appears before `Disable-BitLocker` runs. Choose **No** to report only.

## What is checked

| Area | Content |
|------|---------|
| System & OS | Manufacturer, model, Windows build, license key |
| CPU / BIOS | Cores, temperature (when reported), BIOS serial |
| Secure Boot / BitLocker | Admin only |
| Graphics / display | GPU filter, monitor size |
| Memory | Per-DIMM speed, slot, throttle warning |
| Storage | SSD health, allocation, SMART (admin) |
| Battery | Health, voltage vs design (laptops) |
| Network | Ping to `www.google.com` |
| Device Manager | PnP error codes |
| HP bloatware | On non-HP systems |
| Software | Appx, winget (Full), Windows Update (Full), crash dumps |

## Project layout

| File | Role |
|------|------|
| `FastCheck.ps1` | STA launcher |
| `FastCheck.Core.ps1` | Diagnostics + streaming orchestrator |
| `FastCheck.UI.ps1` | WPF dashboard |
| `Build-FastCheckExe.ps1` | Builds `Fastcheck.exe` via ps2exe |

## Building an executable

```powershell
.\Build-FastCheckExe.ps1
```

Ship **`Fastcheck.exe`** together with **`FastCheck.Core.ps1`** in the same folder (the background runspace loads the core script from disk).

## Architecture notes

- UI thread owns WPF; diagnostics run in an **STA runspace** with `UseNewThread`
- Completed sections enqueue to a **synchronized queue**; a UI `DispatcherTimer` renders cards on the host thread
- Software health uses **job timeouts** so winget/WU cannot hang the app indefinitely

## Limitations

- Snapshot only — values reflect what Windows reports at run time
- Full Scan may show timeout rows if winget or Windows Update is slow or offline
- Elevated runs may change BitLocker only after you confirm the dialog
