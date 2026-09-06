# scripts

Small, single-file scripts. Each one lives in its own folder with a README.

| Script | What it does |
|---|---|
| [tdx-host-check](tdx-host-check/) | Read-only check of whether an Intel host can carry a confidential VM: GPU driver view, CPUID, memory encryption registers, kernel log, and BIOS settings over Redfish. Packs the evidence into a zip. `tdx-bios-set.sh` alongside it stages the TDX BIOS settings over Redfish. |

MIT licence.
