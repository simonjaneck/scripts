#!/usr/bin/env bash
# tdx-host-check.sh
#
# Read-only check of whether an Intel host can carry a confidential VM:
# what the GPU driver sees, what the processor advertises, what the
# firmware enabled (TME, TME-MT, SGX, TDX), and, if a BMC is given, what
# the BIOS settings look like over Redfish. Everything is saved to one
# folder and zipped, so the result can be sent to whoever reads it.
#
# Nothing is changed on the host. The only writes are the output folder
# and, when the msr or cpuid kernel modules are not loaded, a modprobe
# of those two in-tree modules, which goes away at the next reboot.
# Pass --no-modprobe to forbid even that. With --bmc internal, a
# link-local address may be added to the BMC USB interface for the run
# and is removed again at the end.
#
# Usage
#   sudo ./tdx-host-check.sh
#   sudo ./tdx-host-check.sh --bmc internal --bmc-user admin
#   sudo ./tdx-host-check.sh --bmc 10.0.0.5 --bmc-user admin
#   sudo ./tdx-host-check.sh --label after --out /tmp
#
# Options
#   --bmc internal      Read the BIOS over the DGX internal host-to-BMC USB
#                       network interface (enx..., BMC at 169.254.0.17), from
#                       the node itself. If the interface has no link-local
#                       address yet, 169.254.0.18/16 is added for the run and
#                       removed afterwards. The one host change this makes.
#   --bmc <host>        BMC address for the Redfish part, from any machine
#                       that reaches the BMC network. Password is asked for,
#                       or taken from BMC_PASS if set. Never saved.
#   --bmc-user <user>   BMC account. Read access is enough.
#   --system <id>       Redfish system id if not auto-detected (e.g. DGX).
#   --label <text>      Added to the folder name, e.g. before or after.
#   --out <dir>         Where to write. Default: current directory.
#   --no-modprobe       Do not load the msr or cpuid modules.
#   -h, --help          This text.
#
# Exit code is 0 when the run completed, whatever the findings. The
# reading is in summary.txt inside the zip.
#
# Author: Simon Janeck. MIT licence, see LICENSE in the repository.

set -u

BMC=""; BMC_USER=""; SYSTEM_ID=""; LABEL=""; OUT="."; MODPROBE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --bmc) BMC="$2"; shift 2;;
    --bmc-user) BMC_USER="$2"; shift 2;;
    --system) SYSTEM_ID="$2"; shift 2;;
    --label) LABEL="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --no-modprobe) MODPROBE=0; shift;;
    -h|--help) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

HOST="$(hostname -s 2>/dev/null || hostname)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="tdx-host-check-${HOST}${LABEL:+-$LABEL}-${STAMP}"
DIR="${OUT%/}/${NAME}"
mkdir -p "$DIR" || { echo "cannot create $DIR" >&2; exit 1; }
LOG="$DIR/run.log"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
have() { command -v "$1" >/dev/null 2>&1; }
# run <file> <command...>: run a command, save stdout and stderr, never stop.
run() {
  local f="$DIR/$1"; shift
  { printf '$ %s\n' "$*"; "$@"; printf '\n[exit %s]\n' "$?"; } >"$f" 2>&1
}
runsh() {  # same, for a shell pipeline given as one string
  local f="$DIR/$1"; shift
  { printf '$ %s\n' "$*"; bash -c "$*"; printf '\n[exit %s]\n' "$?"; } >"$f" 2>&1
}

if [ "$(id -u)" -ne 0 ]; then
  say "note: not running as root. dmesg, dmidecode, MSR and CPUID reads will be incomplete. Re-run with sudo for the full set."
fi

say "tdx-host-check on $HOST at $STAMP, writing to $DIR"

# ---------------------------------------------------------------- A1 identity
{
  echo "hostname: $(hostname)"
  echo "date_utc: $(date -u)"
  echo "kernel:   $(uname -r)"
  if have dmidecode; then
    for k in system-manufacturer system-product-name system-serial-number bios-vendor bios-version bios-release-date; do
      printf '%-22s %s\n' "$k:" "$(dmidecode -s $k 2>/dev/null || echo unavailable)"
    done
  else
    echo "dmidecode: not installed"
    for f in sys_vendor product_name bios_vendor bios_version bios_date; do
      printf '%-22s %s\n' "$f:" "$(cat /sys/class/dmi/id/$f 2>/dev/null || echo unavailable)"
    done
  fi
  [ -r /etc/dgx-release ] && { echo "--- /etc/dgx-release"; cat /etc/dgx-release; }
  [ -r /etc/os-release ] && { echo "--- /etc/os-release"; grep -E '^(NAME|VERSION)=' /etc/os-release; }
  if have nvidia-smi; then
    echo "--- gpu"; nvidia-smi --query-gpu=index,name,driver_version,vbios_version --format=csv 2>&1
  else
    echo "nvidia-smi: not installed"
  fi
} >"$DIR/A1-identity.txt" 2>&1
say "A1 identity              saved"

# ------------------------------------------------- A2 what the GPU driver sees
if have nvidia-smi; then
  run A2-conf-compute.txt nvidia-smi conf-compute -q
  runsh A2-conf-compute-ready.txt "nvidia-smi conf-compute -grs 2>&1; nvidia-smi conf-compute -gcs 2>&1"
else
  echo "nvidia-smi not installed, no GPU driver view" >"$DIR/A2-conf-compute.txt"
fi
say "A2 GPU driver view       saved"

# ------------------------------------------------ A3 what the processor says
{
  lscpu 2>/dev/null | grep -E 'Model name|^Model:|Socket|Stepping|Vendor|Flags' | cut -c1-2000
  echo
  echo "--- feature flags of interest (count over all logical CPUs)"
  grep -o -w -E 'tme|sgx|sgx_lc|pconfig|tdx_guest|tdx_host_platform|sev|sev_snp' /proc/cpuinfo | sort | uniq -c
  echo
  echo "--- devices"
  ls -l /dev/sgx_enclave /dev/sgx_provision /dev/sgx_vepc /dev/tdx_guest /dev/tdx-guest 2>&1
} >"$DIR/A3-cpu.txt" 2>&1
say "A3 processor flags       saved"

# ------------------------------------------------ A4 kernel messages at boot
{
  if dmesg >/dev/null 2>&1; then
    dmesg | grep -i -E '\bsgx\b|\btdx\b|\btme\b|tme-mt|memory encryption|\bseam\b|virt/tdx|mktme'
  elif have journalctl; then
    journalctl -k -b 2>/dev/null | grep -i -E '\bsgx\b|\btdx\b|\btme\b|tme-mt|memory encryption|\bseam\b|virt/tdx|mktme'
  fi
} >"$DIR/A4-dmesg.txt" 2>&1
[ -s "$DIR/A4-dmesg.txt" ] || echo "no kernel messages about sgx, tdx or tme (or dmesg not readable without root)" >"$DIR/A4-dmesg.txt"
say "A4 kernel messages       saved"

# ------------------------------------------- A5 SGX capability, CPUID leaves
# Uses the cpuid tool if present, otherwise reads /dev/cpu/0/cpuid directly.
cpuid_raw() {  # cpuid_raw <leaf> <subleaf> -> "eax ebx ecx edx" in hex
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import os, struct, sys
leaf, sub = int(sys.argv[1], 0), int(sys.argv[2], 0)
fd = os.open('/dev/cpu/0/cpuid', os.O_RDONLY)
os.lseek(fd, (sub << 32) | leaf, os.SEEK_SET)
a, b, c, d = struct.unpack('<IIII', os.read(fd, 16))
print('%08x %08x %08x %08x' % (a, b, c, d))
PY
}
SGX_PRESENT=""; SGX1=""; ENCL64=""
{
  if have cpuid; then
    echo "--- cpuid tool, leaf 7 subleaf 0"; cpuid -1 -l 0x7 -s 0 | grep -i -E 'SGX|TDX'
    echo "--- cpuid tool, leaf 0x12 subleaf 0"; cpuid -1 -l 0x12 -s 0 | head -14
  fi
  if [ ! -e /dev/cpu/0/cpuid ] && [ "$MODPROBE" = 1 ]; then modprobe cpuid 2>/dev/null; fi
  if [ -r /dev/cpu/0/cpuid ]; then
    r7=$(cpuid_raw 0x7 0); r12=$(cpuid_raw 0x12 0)
    echo "--- raw, leaf 7 sub 0:    $r7"
    echo "--- raw, leaf 0x12 sub 0: $r12"
    if [ -n "$r7" ]; then
      ebx=$((0x$(echo $r7 | cut -d' ' -f2))); ecx=$((0x$(echo $r7 | cut -d' ' -f3)))
      SGX_PRESENT=$(( (ebx>>2)&1 )); echo "leaf7.SGX (silicon has SGX)        = $SGX_PRESENT"
      echo "leaf7.SGX_LC (launch control)      = $(( (ecx>>30)&1 ))"
    fi
    if [ -n "$r12" ]; then
      eax=$((0x$(echo $r12 | cut -d' ' -f1))); edx=$((0x$(echo $r12 | cut -d' ' -f4)))
      SGX1=$(( eax&1 )); ENCL64=$(( (edx>>8)&0xFF ))
      echo "leaf0x12.SGX1 (firmware activated) = $SGX1"
      echo "leaf0x12.SGX2                      = $(( (eax>>1)&1 ))"
      echo "leaf0x12.MaxEnclaveSize_64 (log2)  = $ENCL64"
    fi
  else
    echo "no /dev/cpu/0/cpuid (needs root and the cpuid module)"
  fi
} >"$DIR/A5-cpuid.txt" 2>&1
say "A5 SGX capability leaves saved"

# ------------------------------------------ A6 memory encryption registers
# Uses rdmsr if present, otherwise reads /dev/cpu/0/msr directly.
msr_read() {  # msr_read <addr> -> unsigned decimal, or empty
  if have rdmsr; then rdmsr -u -p 0 "$1" 2>/dev/null; else
    python3 - "$1" <<'PY' 2>/dev/null
import os, struct, sys
fd = os.open('/dev/cpu/0/msr', os.O_RDONLY)
os.lseek(fd, int(sys.argv[1], 0), os.SEEK_SET)
print(struct.unpack('<Q', os.read(fd, 8))[0])
PY
  fi
}
TME_EN=""; KEYID_BITS=""; TDX_KEYS=""; MAX_KEYS=""
{
  if [ ! -e /dev/cpu/0/msr ] && [ "$MODPROBE" = 1 ]; then modprobe msr 2>/dev/null; fi
  if [ -r /dev/cpu/0/msr ] || have rdmsr; then
    v981=$(msr_read 0x981); v982=$(msr_read 0x982); v87=$(msr_read 0x87)
    for pair in "0x981:$v981" "0x982:$v982" "0x87:$v87"; do
      a=${pair%%:*}; v=${pair#*:}
      if [ -n "$v" ]; then printf '%-6s = 0x%016x\n' "$a" "$v"; else printf '%-6s = unreadable (faults, or no access)\n' "$a"; fi
    done
    if [ -n "$v981" ]; then v=$v981; MAX_KEYS=$(((v>>36)&0x7FFF))
      echo "0x981 IA32_TME_CAPABILITY:  aes_xts_128=$((v&1)) with_integrity=$(((v>>1)&1)) bypass_supported=$(((v>>31)&1)) max_keyid_bits=$(((v>>32)&0xF)) max_keys=$MAX_KEYS"; fi
    if [ -n "$v982" ]; then v=$v982; TME_EN=$(((v>>1)&1)); KEYID_BITS=$(((v>>32)&0xF))
      echo "0x982 IA32_TME_ACTIVATE:    lock=$((v&1)) tme_enable=$TME_EN keyid_bits=$KEYID_BITS tdx_keyid_bits=$(((v>>36)&0xF))"; fi
    if [ -n "$v87" ]; then v=$v87; TDX_KEYS=$(((v>>32)&0xFFFFFFFF))
      echo "0x87  IA32_MKTME_KEYID_PARTITIONING: mktme_keys=$((v&0xFFFFFFFF)) tdx_private_keys=$TDX_KEYS"; fi
  else
    echo "no /dev/cpu/0/msr and no rdmsr (needs root and the msr module)"
  fi
} >"$DIR/A6-msr.txt" 2>&1
say "A6 memory encryption MSR saved"

# ------------------------------------------------ B  BIOS settings via BMC
LINK_IF=""; LINK_ADDED=0
if [ "$BMC" = "internal" ]; then
  # DGX systems expose the BMC on an internal USB network interface named
  # enx<mac>, with the BMC preconfigured at 169.254.0.17. See the DGX H100 and
  # B200 user guides, Redfish APIs Support, Connectivity Between the Host and BMC.
  {
    echo "--- candidate interfaces"
    for i in /sys/class/net/enx*; do
      [ -e "$i" ] || continue
      n=$(basename "$i"); drv=$(readlink "$i/device/driver" 2>/dev/null | xargs -r basename)
      echo "$n driver=${drv:-?} carrier=$(cat "$i/carrier" 2>/dev/null || echo ?) addr=$(ip -4 -o addr show dev "$n" 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"
    done
  } >"$DIR/B-internal-link.txt" 2>&1
  for i in /sys/class/net/enx*; do
    [ -e "$i" ] || continue; n=$(basename "$i")
    if ip -4 -o addr show dev "$n" 2>/dev/null | grep -q ' 169\.254\.'; then LINK_IF="$n"; break; fi
  done
  if [ -z "$LINK_IF" ]; then
    for i in /sys/class/net/enx*; do
      [ -e "$i" ] || continue; n=$(basename "$i")
      if [ "$(cat "$i/carrier" 2>/dev/null)" = "1" ] || [ "$(cat "$i/operstate" 2>/dev/null)" = "up" ]; then LINK_IF="$n"; break; fi
    done
    [ -z "$LINK_IF" ] && for i in /sys/class/net/enx*; do [ -e "$i" ] && { LINK_IF=$(basename "$i"); break; }; done
    if [ -n "$LINK_IF" ]; then
      ip link set dev "$LINK_IF" up 2>>"$DIR/B-internal-link.txt"
      if ip addr add 169.254.0.18/16 dev "$LINK_IF" 2>>"$DIR/B-internal-link.txt"; then
        LINK_ADDED=1; echo "added 169.254.0.18/16 to $LINK_IF for this run" >>"$DIR/B-internal-link.txt"
      fi
    fi
  fi
  if [ -n "$LINK_IF" ]; then
    BMC="169.254.0.17"
    echo "using $LINK_IF, BMC at $BMC" >>"$DIR/B-internal-link.txt"
    say "B  internal link: $LINK_IF, BMC at $BMC"
    if ! curl -sk --max-time 10 -o /dev/null "https://$BMC/redfish/v1/" 2>>"$DIR/B-internal-link.txt"; then
      say "B  the BMC does not answer at $BMC over $LINK_IF. Continuing, the Redfish files will show the error."
    fi
  else
    say "B  no enx interface found on this host. Not a DGX, or the internal USB NIC is disabled. Skipping the BIOS part."
    echo "no enx interface found" >>"$DIR/B-internal-link.txt"; BMC=""
  fi
fi
if [ -n "$BMC" ]; then
  if [ -z "$BMC_USER" ]; then read -r -p "BMC user: " BMC_USER; fi
  if [ -z "${BMC_PASS:-}" ]; then read -r -s -p "BMC password (not saved): " BMC_PASS; echo; fi
  CURL=(curl -sk --max-time 30 -u "$BMC_USER:$BMC_PASS")
  jget() { "${CURL[@]}" "https://$BMC$1" | python3 -m json.tool 2>/dev/null; }
  jget /redfish/v1/Systems/ >"$DIR/B0-systems.json"
  if [ -z "$SYSTEM_ID" ]; then
    SYSTEM_ID=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['Members'][0]['@odata.id'].rstrip('/').split('/')[-1])" "$DIR/B0-systems.json" 2>/dev/null)
  fi
  if [ -n "$SYSTEM_ID" ]; then
    say "B  Redfish system id: $SYSTEM_ID"
    jget "/redfish/v1/Systems/$SYSTEM_ID/Bios"    >"$DIR/B1-bios-current.json"
    jget "/redfish/v1/Systems/$SYSTEM_ID/Bios/SD" >"$DIR/B2-bios-pending.json"
  else
    say "B  could not read the Systems collection from $BMC. Check address, account and network. Saved what came back."
  fi
  jget /redfish/v1/UpdateService/FirmwareInventory/HostBIOS_0 >"$DIR/B3-sbios-version.json"
  [ -s "$DIR/B3-sbios-version.json" ] || jget /redfish/v1/UpdateService/FirmwareInventory/ >"$DIR/B3-firmware-inventory.json"
  jget /redfish/v1/Registries/ >"$DIR/B4-registries.json"
  REG=$(python3 -c "import json,sys;m=json.load(open(sys.argv[1]))['Members'];print([x['@odata.id'] for x in m if 'BiosAttributeRegistry' in x['@odata.id']][0])" "$DIR/B4-registries.json" 2>/dev/null)
  if [ -n "$REG" ]; then
    jget "$REG" >"$DIR/B5-registry-index.json"
    LOC=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['Location'][0]['Uri'])" "$DIR/B5-registry-index.json" 2>/dev/null)
    [ -n "$LOC" ] && jget "$LOC" >"$DIR/B6-registry.json"
  fi
  grep -i -E 'tdx|sgx|tme|seam|memory.?encrypt|key.?split|keysplit|expert|integrity|x2apic|mirror' \
    "$DIR"/B1-bios-current.json "$DIR"/B6-registry.json 2>/dev/null >"$DIR/B7-matches.txt"
  [ -s "$DIR/B7-matches.txt" ] || echo "no attribute names match tdx, sgx, tme, seam or expert" >"$DIR/B7-matches.txt"
  unset BMC_PASS CURL
  say "B  BIOS via Redfish       saved"
  if [ "$LINK_ADDED" = 1 ]; then
    ip addr del 169.254.0.18/16 dev "$LINK_IF" 2>>"$DIR/B-internal-link.txt" && echo "removed 169.254.0.18/16 from $LINK_IF" >>"$DIR/B-internal-link.txt"
  fi
else
  say "B  skipped, no --bmc given. The BIOS settings can be read later from any machine that reaches the BMC."
fi

# ------------------------------------------------------------- summary
CPU_CC=$(grep -m1 -i 'CPU CC Capabilities' "$DIR/A2-conf-compute.txt" 2>/dev/null | sed 's/.*: *//')
GPU_CC=$(grep -m1 -i 'GPU CC Capabilities' "$DIR/A2-conf-compute.txt" 2>/dev/null | sed 's/.*: *//')
MODEL=$(grep -m1 'Model name' "$DIR/A3-cpu.txt" | sed 's/.*: *//')
BIOSV=$(grep -m1 -E 'bios-version|bios_version' "$DIR/A1-identity.txt" | sed 's/.*: *//')
FLAG_TDX=$(grep -c -w tdx_host_platform "$DIR/A3-cpu.txt" 2>/dev/null)
{
  echo "tdx-host-check summary"
  echo "host:            $HOST"
  echo "run at (UTC):    $STAMP"
  echo "processor:       ${MODEL:-unknown}"
  echo "bios version:    ${BIOSV:-unknown}"
  echo
  echo "GPU driver, CPU CC Capabilities:  ${CPU_CC:-not available}"
  echo "GPU driver, GPU CC Capabilities:  ${GPU_CC:-not available}"
  echo "cpuinfo tdx_host_platform flag:   $([ "${FLAG_TDX:-0}" -gt 0 ] && echo present || echo absent)"
  echo "SGX in silicon (leaf 7):          ${SGX_PRESENT:-unread}"
  echo "SGX activated by firmware (0x12): ${SGX1:-unread}"
  echo "TME enabled (MSR 0x982):          ${TME_EN:-unread}"
  echo "MKTME key id bits allocated:      ${KEYID_BITS:-unread}"
  echo "TDX private keys (MSR 0x87):      ${TDX_KEYS:-unread}"
  echo "MKTME max keys (MSR 0x981):       ${MAX_KEYS:-unread}"
  echo
  echo "reading:"
  if echo "${CPU_CC:-}" | grep -q -i 'TDX'; then
    echo "  The GPU driver sees a host TDX capability. The host can carry a confidential VM once the software above it is in place."
  elif [ "${TME_EN:-}" = "1" ] && [ "${TDX_KEYS:-0}" -gt 0 ] 2>/dev/null; then
    echo "  Firmware has TME on and keys reserved for TDX, but the GPU driver does not report a host capability. Check the SEAM loader setting and the kernel."
  elif [ "${TME_EN:-}" = "0" ]; then
    echo "  Memory encryption is switched off in firmware. TDX cannot be active. The BIOS settings are the next thing to read."
    [ "${SGX_PRESENT:-}" = "1" ] && [ "${SGX1:-}" = "0" ] && echo "  SGX is present in silicon and not activated by firmware, the same picture."
  else
    echo "  Not enough was readable to decide. Re-run as root, and send the folder anyway."
  fi
} >"$DIR/summary.txt"
cat "$DIR/summary.txt" | tee -a "$LOG"

# ------------------------------------------------------------- zip
ZIP="${OUT%/}/${NAME}.zip"
if have zip; then
  (cd "${OUT%/}" && zip -q -r "${NAME}.zip" "$NAME")
else
  python3 -c "import shutil,sys;shutil.make_archive(sys.argv[1],'zip',sys.argv[2],sys.argv[3])" "${OUT%/}/${NAME}" "${OUT%/}" "$NAME"
fi
say ""
say "done. send this file: $ZIP"
