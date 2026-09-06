# tdx-host-check

Two scripts. `tdx-host-check.sh` reads, without changing anything, whether an Intel host can carry a confidential virtual machine, and packs the evidence into a zip. `tdx-bios-set.sh` stages the BIOS settings for TDX over Redfish, for the node to apply at its next boot.

The check script answers, from the operating system:

- what the NVIDIA driver reports as host and GPU confidential computing capability (`nvidia-smi conf-compute -q`)
- what the processor advertises (`/proc/cpuinfo` flags, CPUID leaf 7 and leaf 0x12 for SGX)
- what the firmware enabled at boot (`IA32_TME_CAPABILITY`, `IA32_TME_ACTIVATE`, `IA32_MKTME_KEYID_PARTITIONING`), decoded
- what the kernel said about SGX, TME and TDX
- the system, BIOS and driver versions

and, if a BMC address is given, it reads the BIOS settings and the BIOS attribute registry over Redfish and greps them for the TDX, SGX, TME, SEAM and expert-mode items.

Written for DGX H100 class systems with 4th generation Xeon hosts, where the question is whether TDX can be turned on at all. It runs on any Intel Linux host.

## Run everything with one line

`run.sh` fetches both scripts, runs the read-only check over the internal BMC link, shows the current and pending BIOS settings, and puts every zip in one folder. It asks for the BMC login once and offers to save it.

```bash
curl -fsSL https://raw.githubusercontent.com/simonjaneck/scripts/main/tdx-host-check/run.sh | sudo bash
```

Options after `bash -s --`: `--stage enable` or `--stage disable` to continue into `tdx-bios-set.sh`, which checks the request against the firmware registry and asks before sending; `--reboot` to offer the restart afterwards; `--no-bmc` for part A only; `--bmc <host>` for a BMC address instead of the internal link; `--ref <commit>` to pin a version; `--local` to use scripts already next to it; `--yes` to answer every question. Output lands in `/tmp/tdx-host-check-<date>/`.

## Run the check on its own

Fetch the one file and run it. No checkout needed.

```bash
curl -fsSL https://raw.githubusercontent.com/simonjaneck/scripts/main/tdx-host-check/tdx-host-check.sh -o tdx-host-check.sh
chmod +x tdx-host-check.sh
sudo ./tdx-host-check.sh
sudo ./tdx-host-check.sh --bmc internal --bmc-user admin     # with the BIOS part, over the DGX internal link
sudo ./tdx-host-check.sh --bmc 10.0.0.5 --bmc-user admin     # with the BIOS part, over the BMC network
sudo ./tdx-host-check.sh --label after                         # after a BIOS change
```

`--bmc internal` uses the host-to-BMC USB network interface that DGX systems carry, usually named `enx<mac>`, with the BMC preconfigured at `169.254.0.17`. The node then reads its own BIOS settings without any route to the BMC network. The system does not ship with the host side configured, so the script lists the USB interfaces it found, says exactly what it would run (`ip link set up` and `ip addr add 169.254.0.18/16`), and asks before doing it. At the end it asks whether to keep the address or remove it. `--yes` answers yes to both. That link is documented in the DGX H100 and B200 user guides under Redfish APIs Support, Connectivity Between the Host and BMC.

Or with the repository: `git clone https://github.com/simonjaneck/scripts.git && cd scripts/tdx-host-check`.

Output is a folder and a zip next to it, named `tdx-host-check-<host>-<label>-<timestamp>`. Send the zip.

`summary.txt` inside carries the decoded reading. `run.log` carries what the script printed. Every other file is the raw output of one command, with the command on its first line.

## BMC login, once

Both scripts read the BMC account from a file with two lines, mode 600:

```
USERNAME=admin
PASSWORD=secret
```

Create it by hand:

```bash
umask 077; printf 'USERNAME=%s\nPASSWORD=%s\n' admin 'secret' > ~/.tdx-bmc.auth
```

Or let the check script write it after the first successful login: `sudo ./tdx-host-check.sh --bmc internal --bmc-user admin --save-auth`. Both scripts use `~/.tdx-bmc.auth` by default when it exists, or the path given with `--auth-file`. Under `sudo` the home directory is root's, so the file lands in `/root/.tdx-bmc.auth` and is read from there. Without a file, the scripts ask for the password, or take it from `BMC_PASS`. The password is never written to the output folder.

## Staging the settings: tdx-bios-set.sh

The BMC's BIOS resource has a pending-settings object, `Systems/<id>/Bios/SD`. Writing to it stages values that the firmware applies at the next boot. The script does that for the TDX set and nothing else.

```bash
sudo ./tdx-bios-set.sh --bmc internal --show                # current and pending values, read-only
sudo ./tdx-bios-set.sh --bmc internal --enable --dry-run    # print the request, send nothing
sudo ./tdx-bios-set.sh --bmc internal --enable              # stage TME, TME-MT, SGX, TDX, SEAM loader on, integrity off, PRM 256M, key split 1
sudo ./tdx-bios-set.sh --bmc internal --enable --reboot     # and send a graceful restart through the BMC, after asking
sudo ./tdx-bios-set.sh --bmc internal --disable             # stage the revert
sudo ./tdx-bios-set.sh --bmc internal --set PrmSgxSize=512M # one attribute of your choice
```

Before anything is sent, the script reads the firmware's own BIOS attribute registry and checks the request against it: every attribute must exist on that firmware and be writable, every value must be one the firmware lists as allowed or inside its integer range, and for `--enable` the preconditions must already hold (Extended APIC on, NUMA on, 46-bit address limit off). It prints the check as a table, current value beside requested value, and stops with nothing sent if anything fails. Only when everything passes does it ask for confirmation. `--dry-run` stops right after the check.

What to know before using it:

- **A reboot is required.** These settings are programmed by the firmware during POST. Nothing changes until the node restarts, and the first boot after enabling memory encryption and SGX takes several minutes longer than usual. Drain the node first.
- **No BIOS screen and no expert mode.** The attributes are exposed over Redfish on DGX H100 SBIOS 01.06.07 regardless of the setup menu.
- **Every run saves** the settings before, the request, the BMC's answer and the pending settings after, zipped. `--show` and `--dry-run` change nothing.
- **Revert** with `--disable` and another reboot. If the node will not boot, the BMC's `Bios.ResetBios` action restores firmware defaults.
- **Attribute names** are the DGX SBIOS ones: `EnableTme`, `EnableMktme`, `EnableGlobalIntegrity`, `EnableSgx`, `PrmSgxSize`, `EnableTdx`, `EnableTdxSeamldr`, `KeySplit`. Run `--show` first on a different firmware and check they exist.

## What it needs

- Root, for `dmesg`, `dmidecode`, and the MSR and CPUID device files. Without root it still runs and says what it could not read.
- `python3`, which every DGX OS and Ubuntu has. `cpuid` and `msr-tools` are used if present and are not required: the script reads `/dev/cpu/0/cpuid` and `/dev/cpu/0/msr` directly when they are missing.
- The `msr` and `cpuid` kernel modules. If they are not loaded the script loads them, which does not survive a reboot. `--no-modprobe` forbids it. With `--bmc internal` a link-local address is added to the BMC USB interface after confirmation, and removed afterwards unless you choose to keep it. Those are the only two changes it can make.
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
