#!/usr/bin/env bash
# tdx-bios-set.sh
#
# Stage the BIOS settings for Intel TDX on a DGX class host over Redfish,
# without the BIOS screen. Writes the pending settings resource
# (Systems/<id>/Bios/SD), which the firmware applies at the next boot.
# Nothing changes until the node reboots, and a reboot is required for
# any of these settings to take effect: they are programmed by firmware
# during POST.
#
# Usage
#   ./tdx-bios-set.sh --bmc internal --auth-file ~/.tdx-bmc.auth --show
#   sudo ./tdx-bios-set.sh --bmc internal --auth-file ~/.tdx-bmc.auth --enable
#   sudo ./tdx-bios-set.sh --bmc internal --auth-file ~/.tdx-bmc.auth --enable --reboot
#   sudo ./tdx-bios-set.sh --bmc internal --auth-file ~/.tdx-bmc.auth --disable
#   ./tdx-bios-set.sh --bmc 10.0.0.5 --bmc-user admin --show
#
# Actions, one of
#   --show              Print current and pending values of the TDX related
#                       attributes. Read-only.
#   --enable            Stage TME, TME-MT, SGX, TDX, SEAM loader on, memory
#                       integrity off, key split 1.
#   --disable           Stage all of them back to Disabled, key split 1.
#   --set NAME=VALUE    Stage one attribute. Repeatable. For values the two
#                       presets do not cover, e.g. --set PrmSgxSize=512M
#
# Options
#   --bmc internal      Use the DGX internal host-to-BMC USB link, BMC at
#                       169.254.0.17. Needs root. Asks before configuring
#                       the interface if it has no address yet.
#   --bmc <host>        BMC address, from any machine that reaches it.
#   --auth-file <path>  File with USERNAME=... and PASSWORD=... lines,
#                       mode 600. Default ~/.tdx-bmc.auth if it exists.
#   --bmc-user <user>   BMC account, if no auth file. Password is asked
#                       for, or taken from BMC_PASS.
#   --system <id>       Redfish system id if not auto-detected (e.g. DGX).
#   --reboot            After staging, ask, then send a graceful restart
#                       through the BMC so the settings apply.
#   --dry-run           Print the request that would be sent, send nothing.
#   --out <dir>         Where to save before, request, response and pending.
#   --yes, -y           Answer yes to every question.
#   -h, --help          This text.
#
# Every run saves the current settings before any change, the request body,
# the BMC's response and the pending settings after, in one folder, zipped.
# To revert, run --disable and reboot again. If the node does not boot,
# the BMC's Bios.ResetBios action restores firmware defaults.
#
# Author: Simon Janeck. MIT licence, see LICENSE in the repository.

set -u

ACTION=""; SETS=(); BMC=""; BMC_USER=""; AUTH=""; SYSTEM_ID=""; REBOOT=0; DRY=0; OUT="."; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --show) ACTION=show; shift;;
    --enable) ACTION=enable; shift;;
    --disable) ACTION=disable; shift;;
    --set) SETS+=("$2"); ACTION=${ACTION:-set}; shift 2;;
    --bmc) BMC="$2"; shift 2;;
    --bmc-user) BMC_USER="$2"; shift 2;;
    --auth-file) AUTH="$2"; shift 2;;
    --system) SYSTEM_ID="$2"; shift 2;;
    --reboot) REBOOT=1; shift;;
    --dry-run) DRY=1; shift;;
    --out) OUT="$2"; shift 2;;
    --yes|-y) YES=1; shift;;
    -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[ -n "$ACTION" ] || { echo "one of --show, --enable, --disable or --set is required. See --help." >&2; exit 2; }
[ -n "$BMC" ] || { echo "--bmc internal or --bmc <host> is required" >&2; exit 2; }

HOST="$(hostname -s 2>/dev/null || hostname)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="tdx-bios-set-${HOST}-${ACTION}-${STAMP}"
DIR="${OUT%/}/${NAME}"
mkdir -p "$DIR" || { echo "cannot create $DIR" >&2; exit 1; }
LOG="$DIR/run.log"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
confirm() { [ "$YES" = 1 ] && return 0; local a; read -r -p "$1 [y/N] " a </dev/tty; case "$a" in y|Y|yes|YES) return 0;; *) return 1;; esac; }

# ------------------------------------------------------------ credentials
[ -z "$AUTH" ] && [ -r "$HOME/.tdx-bmc.auth" ] && AUTH="$HOME/.tdx-bmc.auth"
if [ -n "$AUTH" ]; then
  [ -r "$AUTH" ] || { echo "cannot read $AUTH" >&2; exit 1; }
  # parse rather than source: in zsh USERNAME is a read-only builtin
  BMC_USER=$(sed -n 's/^USERNAME=//p' "$AUTH" | head -1 | tr -d '\r')
  BMC_PASS=$(sed -n 's/^PASSWORD=//p' "$AUTH" | head -1 | tr -d '\r')
  [ -n "$BMC_USER" ] && [ -n "$BMC_PASS" ] || { echo "$AUTH must contain USERNAME= and PASSWORD= lines" >&2; exit 1; }
  perm=$(stat -c %a "$AUTH" 2>/dev/null); [ "$perm" = 600 ] || say "note: $AUTH has mode $perm, consider chmod 600"
fi
[ -n "$BMC_USER" ] || read -r -p "BMC user: " BMC_USER
[ -n "${BMC_PASS:-}" ] || { read -r -s -p "BMC password (not saved): " BMC_PASS; echo; }

# ------------------------------------------------------- internal link
if [ "$BMC" = "internal" ]; then
  [ "$(id -u)" -eq 0 ] || say "note: --bmc internal may need root to configure the interface"
  CANDS=""
  for i in /sys/class/net/*; do
    n=$(basename "$i"); [ "$n" = lo ] && continue
    dev=$(readlink -f "$i/device" 2>/dev/null)
    case "$n:$dev" in enx*|*usb*|*:*/usb*) CANDS="$CANDS $n";; esac
  done
  LINK_IF=""
  for n in $CANDS; do ip -4 -o addr show dev "$n" 2>/dev/null | grep -q ' 169\.254\.' && { LINK_IF="$n"; break; }; done
  if [ -z "$LINK_IF" ]; then
    [ -n "$CANDS" ] || { say "no USB network interface to the BMC found on this host"; exit 1; }
    for n in $CANDS; do [ "$(cat /sys/class/net/$n/carrier 2>/dev/null)" = 1 ] && { LINK_IF="$n"; break; }; done
    [ -z "$LINK_IF" ] && LINK_IF=$(echo $CANDS | awk '{print $1}')
    say "the internal link $LINK_IF has no address. Would run: ip link set dev $LINK_IF up; ip addr add 169.254.0.18/16 dev $LINK_IF"
    confirm "Configure $LINK_IF now?" || { say "left as is, nothing done"; exit 1; }
    ip link set dev "$LINK_IF" up && sleep 2 && ip addr add 169.254.0.18/16 dev "$LINK_IF" || { say "could not configure $LINK_IF"; exit 1; }
  fi
  BMC=169.254.0.17
  say "using $LINK_IF, BMC at $BMC"
fi

# ------------------------------------------------------------- redfish
CURL=(curl -skL --compressed --max-time 60 -u "$BMC_USER:$BMC_PASS")
rf_get() {  # rf_get <path> -> pretty json on stdout, status in RF_CODE
  RF_CODE=$("${CURL[@]}" -o "$DIR/.raw" -w '%{http_code}' "https://$BMC$1")
  if head -c 2 "$DIR/.raw" 2>/dev/null | od -An -tx1 | grep -q '1f 8b'; then gunzip -c "$DIR/.raw"; else cat "$DIR/.raw"; fi | python3 -m json.tool 2>/dev/null
  rm -f "$DIR/.raw"
}
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "https://$BMC/redfish/v1/Systems")
case "$code" in
  2*) ;;
  401|403) say "the BMC at $BMC rejected the login for $BMC_USER (HTTP $code)"; exit 1;;
  *) say "no usable answer from $BMC (HTTP $code)"; exit 1;;
esac
if [ -z "$SYSTEM_ID" ]; then
  SYSTEM_ID=$(rf_get /redfish/v1/Systems | python3 -c "import json,sys;print(json.load(sys.stdin)['Members'][0]['@odata.id'].rstrip('/').split('/')[-1])" 2>/dev/null)
fi
[ -n "$SYSTEM_ID" ] || { say "could not determine the Redfish system id, pass --system"; exit 1; }
BIOS="/redfish/v1/Systems/$SYSTEM_ID/Bios"
say "system $SYSTEM_ID, BIOS resource $BIOS"

KEYS='EnableTme EnableTmeBypass EnableMktme EnableGlobalIntegrity EnableSgx PrmSgxSize EnableTdx EnableTdxSeamldr KeySplit ProcessorX2apic NumaEn CpuPaLimit'
rf_get "$BIOS"    >"$DIR/before-current.json"; [ "$RF_CODE" = 200 ] || say "warning: GET $BIOS returned HTTP $RF_CODE"
rf_get "$BIOS/SD" >"$DIR/before-pending.json"
show_table() {  # show_table <current.json> <pending.json>
  python3 - "$1" "$2" "$KEYS" <<'PY'
import json, sys
def attrs(p):
    try: d = json.load(open(p)); return d.get('Attributes', {})
    except Exception: return {}
c, p = attrs(sys.argv[1]), attrs(sys.argv[2])
print('%-24s %-22s %-22s' % ('attribute', 'current', 'pending'))
for k in sys.argv[3].split():
    cv, pv = c.get(k, '<absent>'), p.get(k, '<absent>')
    flag = '  <- change staged' if (k in p and pv != cv) else ''
    print('%-24s %-22s %-22s%s' % (k, cv, pv, flag))
PY
}
say "--- settings before"
show_table "$DIR/before-current.json" "$DIR/before-pending.json" | tee -a "$LOG"

if [ "$ACTION" = show ]; then
  say "read-only, nothing staged"
  rm -f "$DIR/.raw"; (cd "${OUT%/}" && { command -v zip >/dev/null && zip -q -r "$NAME.zip" "$NAME" || python3 -c "import shutil,sys;shutil.make_archive(sys.argv[1],'zip',sys.argv[2],sys.argv[3])" "$NAME" . "$NAME"; })
  say "saved ${OUT%/}/$NAME.zip"; exit 0
fi

# ------------------------------------------------------------ the request
case "$ACTION" in
  enable)  BODY='{"Attributes":{"EnableTme":"Enabled","EnableMktme":"Enabled","EnableGlobalIntegrity":"Disabled","EnableSgx":"Enabled","EnableTdx":"Enabled","EnableTdxSeamldr":"Enabled","KeySplit":1}}';;
  disable) BODY='{"Attributes":{"EnableTme":"Disabled","EnableMktme":"Disabled","EnableGlobalIntegrity":"Disabled","EnableSgx":"Disabled","EnableTdx":"Disabled","EnableTdxSeamldr":"Disabled","KeySplit":1}}';;
  set)     BODY=$(python3 - "${SETS[@]}" <<'PY'
import json, sys
a = {}
for s in sys.argv[1:]:
    k, v = s.split('=', 1)
    a[k] = int(v) if v.isdigit() else v
print(json.dumps({'Attributes': a}))
PY
);;
esac
printf '%s\n' "$BODY" >"$DIR/request-body.json"
say "--- request: PATCH $BIOS/SD"
say "$BODY"
if [ "$DRY" = 1 ]; then say "dry run, nothing sent"; exit 0; fi
say "This stages the values above. They take effect at the next boot of this node, and the first boot after enabling memory encryption and SGX takes several minutes longer than usual."
confirm "Stage these settings on $SYSTEM_ID via $BMC?" || { say "not sent"; exit 1; }
RESP_CODE=$("${CURL[@]}" -o "$DIR/response.json" -w '%{http_code}' --request PATCH "https://$BMC$BIOS/SD" \
  -H 'Content-Type: application/json' -H 'If-Match: *' --data-raw "$BODY")
say "BMC answered HTTP $RESP_CODE"
[ -s "$DIR/response.json" ] && head -c 800 "$DIR/response.json" | tee -a "$LOG" && echo
sleep 2
rf_get "$BIOS/SD" >"$DIR/after-pending.json"
say "--- settings after staging (pending applies at next boot)"
show_table "$DIR/before-current.json" "$DIR/after-pending.json" | tee -a "$LOG"
case "$RESP_CODE" in 2*) ;; *) say "the BMC did not accept the request. Nothing is staged. See response.json.";; esac

# ------------------------------------------------------------- reboot
if [ "$REBOOT" = 1 ] && case "$RESP_CODE" in 2*) true;; *) false;; esac; then
  say "A graceful restart will be sent through the BMC. Make sure the node is drained. Expect ten to twenty minutes before the OS is back."
  if confirm "Reboot $SYSTEM_ID now?"; then
    RC=$("${CURL[@]}" -o "$DIR/reset-response.json" -w '%{http_code}' --request POST "https://$BMC/redfish/v1/Systems/$SYSTEM_ID/Actions/ComputerSystem.Reset" \
      -H 'Content-Type: application/json' --data-raw '{"ResetType":"GracefulRestart"}')
    say "reset request answered HTTP $RC. When the node is back, run tdx-host-check.sh --bmc internal --label after and compare."
  else
    say "not rebooted. The settings stay pending until the next boot, whenever that is."
  fi
else
  [ "$REBOOT" = 0 ] && say "not rebooting. The settings stay pending until the next boot. Reboot when the node is drained, then run tdx-host-check.sh --label after."
fi
unset BMC_PASS CURL
rm -f "$DIR/.raw"
(cd "${OUT%/}" && { command -v zip >/dev/null && zip -q -r "$NAME.zip" "$NAME" || python3 -c "import shutil,sys;shutil.make_archive(sys.argv[1],'zip',sys.argv[2],sys.argv[3])" "$NAME" . "$NAME"; })
say "saved ${OUT%/}/$NAME.zip"
