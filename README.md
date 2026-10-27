# NAC Wave 4 Infotainment Updater

[![Tests](https://github.com/arjankapteijn/nac-infotainment-updater/actions/workflows/tests.yml/badge.svg)](https://github.com/arjankapteijn/nac-infotainment-updater/actions/workflows/tests.yml)

> **This is a maintained fork of [hjertmann/nac-infotainment-updater](https://github.com/hjertmann/nac-infotainment-updater).**
> All credit for the original scripts goes to the upstream author. The upstream repository has not been updated since March 2026 and several pull requests are still waiting for review, so this fork collects those fixes in one place. If upstream becomes active again, everything here is available to merge back.
>
> Changes compared to upstream:
>
> - Download resume no longer loops forever when the server ignores Range requests (macOS and Windows) — [#9](https://github.com/hjertmann/nac-infotainment-updater/issues/9), [#10](https://github.com/hjertmann/nac-infotainment-updater/pull/10)
> - No more false "No SWL/ directory found" error on a valid archive (macOS) — [#11](https://github.com/hjertmann/nac-infotainment-updater/issues/11)
> - An empty or invalid license download is rejected instead of reported as success — [#12](https://github.com/hjertmann/nac-infotainment-updater/issues/12)
> - European map updated to `21.0.0-r0` — [#1](https://github.com/hjertmann/nac-infotainment-updater/issues/1)
> - Windows fixes for single-USB selection, disk initialization, BITS without Range support, the false "archive corrupted" report and UTF-8 parsing, from [#7](https://github.com/hjertmann/nac-infotainment-updater/pull/7) by [@ac-uy](https://github.com/ac-uy) and [#5](https://github.com/hjertmann/nac-infotainment-updater/pull/5) by [@akarshvijayan](https://github.com/akarshvijayan)
> - The Windows map script no longer leaves a background BITS download running after you abort it
> - Automated tests for both platforms, run on every push — see [Testing](#testing)

Scripts to prepare a USB drive for updating the Continental NAC Wave 4 infotainment system found in Peugeot, Citroën, DS, and Opel/Vauxhall vehicles (~2017 onwards).

---

## Why this exists

The official Citroën/Peugeot/DS/Opel Update apps are supposed to do exactly what these scripts do: download the firmware and map files from Stellantis's servers and prepare a USB drive for installation. Since February 4, 2026, the official apps have been downloading a broken firmware file from Stellantis's CloudFront CDN that fails with a **"Version not compatible with hardware"** error.

These scripts do what the vendor updater was supposed to do — nothing more. They download from Stellantis's own `majestic-web.mpsa.com` server (firmware/licenses) and TomTom's CDN (maps), structure the USB drive exactly as the NAC expects, and clean up macOS metadata files that can interfere with the install.

**This project does not circumvent any DRM, licensing restrictions, or access controls.** All files are downloaded from official Stellantis and TomTom servers using the same API endpoints the official apps use. The license file for your specific NAC unit is fetched from Stellantis's own licensing API using your unit's UIN — the same process the official app performs.

---

## Use at your own risk

**Tested on:** Citroën C5 Aircross Plug-in Hybrid, upgrading from firmware `42.01.72.32_NAC-r0` to `44.07.33.32_NAC-r0`, using the macOS scripts.

**This fork** was used for a real firmware update on a Citroën C5 Aircross, from `42.03.33.42_NAC-r0` to `44.07.33.32_NAC-r0`, with the macOS firmware script (including the download-resume and license fixes), followed by the European map `21.0.0-r0` with the macOS map script.

**Windows scripts** have now been tested end-to-end on a DS 7 Crossback, upgrading from `40.04.20.22_NAC-r0` to `44.07.33.32_NAC-r0` (Windows 10/11, PowerShell 5.1). A few Windows-specific bugs were found and fixed in the process — see [windows/README.md](windows/README.md#windows-specific-fixes-2026-07) for details.

Updating car infotainment systems always carries some risk. Do not turn off the engine during installation.

---

## Platform scripts

| Platform | Scripts | Status |
|---|---|---|
| [macOS](macos/README.md) | `prepare_nac_update_mac.sh`, `prepare_nac_map_update_mac.sh` | Tested |
| [Windows](windows/README.md) | `Prepare-NacFirmwareUpdate.ps1`, `Prepare-NacMapUpdate.ps1` | Tested (firmware) |

See the platform-specific README for prerequisites, usage, and troubleshooting:

- **[macOS instructions →](macos/README.md)**
- **[Windows instructions →](windows/README.md)**

---

## Compatible vehicles

Any PSA/Stellantis vehicle with a Continental NAC Wave 4 infotainment system, including:

- Citroën C5 Aircross, C4, C3 Aircross, Berlingo, C5 X
- Peugeot 208, 2008, 308, 3008, 508, 5008, Rifter, Partner
- DS 3, DS 4, DS 7, DS 9
- Opel/Vauxhall Corsa, Mokka, Grandland, Combo
- Toyota Proace (PSA-based models)

To confirm you have a NAC Wave 4: Settings → System info → System version. Firmware versions starting with **42.xx** or **44.xx** are Wave 4.

---

## Quick start

**Always install firmware first, then maps.**

### macOS

```bash
brew install coreutils gnu-tar
bash macos/prepare_nac_update_mac.sh       # firmware (~5.9 GB)
bash macos/prepare_nac_map_update_mac.sh   # maps (~19 GB, optional)
```

### Windows (PowerShell, run as Administrator)

```powershell
.\windows\Prepare-NacFirmwareUpdate.ps1    # firmware (~5.9 GB)
.\windows\Prepare-NacMapUpdate.ps1         # maps (~19 GB, optional)
```

You will need your **NAC UIN** (20-character hex code) for the firmware update. See the platform README for how to find it.

---

## Problems?

Please [open a GitHub issue](../../issues) with your vehicle model, current firmware version, OS, and a description of what went wrong.

---

## Testing

Both platforms have a test suite that runs on every push ([GitHub Actions](https://github.com/arjankapteijn/nac-infotainment-updater/actions/workflows/tests.yml)). The tests load the script functions and run them against small local fixtures and a local test server, so they download nothing and never touch a real disk:

```bash
bash tests/macos/run_tests.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File tests\windows\Run-Tests.ps1
```

They cover USB drive selection, archive validation, extraction, download resume (with and without server Range support) and, on macOS, the license check. On Windows, run as Administrator to include the format test, which uses a throwaway VHD.

In addition, the Windows scripts were checked by hand in a Windows 11 VM (PowerShell 5.1): formatting and extraction on a real USB stick, and real downloads from the Stellantis and TomTom servers, interrupted and resumed. The macOS firmware and map scripts from this fork were also used for a full install in a car (see [Use at your own risk](#use-at-your-own-risk)); the Windows scripts from this fork have not been used in a car yet.

---

## License

These scripts are provided as-is for personal use. The firmware and map files are copyrighted by Stellantis/Continental/TomTom and are downloaded from their official servers. Use at your own risk.
