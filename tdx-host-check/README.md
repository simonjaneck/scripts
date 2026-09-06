# tdx-host-check

One script that reads, without changing anything, whether an Intel host can carry a confidential virtual machine, and packs the evidence into a zip.

It answers, from the operating system:

- what the NVIDIA driver reports as host and GPU confidential computing capability (`nvidia-smi conf-compute -q`)
- what the processor advertises (`/proc/cpuinfo` flags, CPUID leaf 7 and leaf 0x12 for SGX)
- what the firmware enabled at boot (`IA32_TME_CAPABILITY`, `IA32_TME_ACTIVATE`, `IA32_MKTME_KEYID_PARTITIONING`), decoded
- what the kernel said about SGX, TME and TDX
- the system, BIOS and driver versions

and, if a BMC address is given, it reads the BIOS settings and the BIOS attribute registry over Redfish and greps them for the TDX, SGX, TME, SEAM and expert-mode items.

Written for DGX H100 class systems with 4th generation Xeon hosts, where the question is whether TDX can be turned on at all. It runs on any Intel Linux host.

## Run

Fetch the one file and run it. No checkout needed.

```bash
curl -fsSL https://raw.githubusercontent.com/simonjaneck/scripts/main/tdx-host-check/tdx-host-check.sh -o tdx-host-check.sh
chmod +x tdx-host-check.sh
sudo ./tdx-host-check.sh
sudo ./tdx-host-check.sh --bmc internal --bmc-user admin     # with the BIOS part, over the DGX internal link
sudo ./tdx-host-check.sh --bmc 10.0.0.5 --bmc-user admin     # with the BIOS part, over the BMC network
sudo ./tdx-host-check.sh --label after                         # after a BIOS change
```

`--bmc internal` uses the host-to-BMC USB network interface that DGX systems carry, named `enx<mac>`, with the BMC preconfigured at `169.254.0.17`. The node then reads its own BIOS settings without any route to the BMC network. If the interface has no link-local address yet, `169.254.0.18/16` is added for the run and removed at the end. That is documented in the DGX H100 and B200 user guides under Redfish APIs Support, Connectivity Between the Host and BMC.

Or with the repository: `git clone https://github.com/simonjaneck/scripts.git && cd scripts/tdx-host-check`.

Output is a folder and a zip next to it, named `tdx-host-check-<host>-<label>-<timestamp>`. Send the zip.

`summary.txt` inside carries the decoded reading. `run.log` carries what the script printed. Every other file is the raw output of one command, with the command on its first line.

## What it needs

- Root, for `dmesg`, `dmidecode`, and the MSR and CPUID device files. Without root it still runs and says what it could not read.
- `python3`, which every DGX OS and Ubuntu has. `cpuid` and `msr-tools` are used if present and are not required: the script reads `/dev/cpu/0/cpuid` and `/dev/cpu/0/msr` directly when they are missing.
- The `msr` and `cpuid` kernel modules. If they are not loaded the script loads them, which does not survive a reboot. `--no-modprobe` forbids it. With `--bmc internal` a link-local address may be added to the BMC USB interface for the run and removed afterwards. Those are the only two changes it can make.
- `curl` for the Redfish part. The BMC password is asked for at the prompt, or taken from `BMC_PASS`, and is not written anywhere. The saved JSON does contain whatever the BMC returns, including hostnames and firmware versions.

## Reading the result

| Line in summary.txt | Means |
|---|---|
| `CPU CC Capabilities: INTEL TDX` | The GPU driver sees a host TEE. Pass. |
| `CPU CC Capabilities: None` with `TME enabled: 0` | Firmware ships memory encryption off. TDX cannot be active. Read the BIOS settings next. |
| `SGX in silicon: 1` and `SGX activated by firmware: 0` | The processor has SGX and the firmware did not turn it on. SGX is a prerequisite for TDX. |
| `TME enabled: 1`, `TDX private keys > 0`, driver still `None` | Firmware did its part. Look at the SEAM loader setting and whether the kernel has TDX host support. |
| `tdx_host_platform flag: present` | Kernel has TDX host support and TDX is enabled. Only appears on newer kernels. |

## Register decoding

| Register | Fields used |
|---|---|
| `0x981 IA32_TME_CAPABILITY` | bit 0 AES-XTS-128, bit 1 with integrity, bit 31 bypass, bits 35:32 max key id bits, bits 50:36 max keys |
| `0x982 IA32_TME_ACTIVATE` | bit 0 lock, bit 1 TME enable, bits 35:32 key id bits, bits 39:36 TDX reserved key id bits |
| `0x87 IA32_MKTME_KEYID_PARTITIONING` | bits 31:0 MKTME keys, bits 63:32 TDX private keys |

Sources: Intel Software Developer's Manual, Intel TDX module specification, NVIDIA confidential computing deployment guide, Intel and Canonical TDX enabling documentation.

## Licence

MIT.
