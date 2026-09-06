#!/usr/bin/env bash
# run.sh
#
# One file to fetch and run the whole host check. Downloads tdx-host-check.sh
# and tdx-bios-set.sh from the repository, runs the read-only check over the
# internal BMC link, shows the current and pending BIOS settings, and, only
# if asked with --stage, hands over to tdx-bios-set.sh, which does its own
# registry check and asks before staging anything.
#
#   curl -fsSL https://raw.githubusercontent.com/simonjaneck/scripts/main/tdx-host-check/run.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/simonjaneck/scripts/main/tdx-host-check/run.sh | sudo bash -s -- --stage enable
#
# Options
#   --bmc-user <user>   BMC account. Asked for if no auth file exists.
#   --auth-file <path>  Existing USERNAME=/PASSWORD= file, mode 600.
#                       Default ~/.tdx-bmc.auth if present.
#   --no-save           Do not offer to save the BMC login for next time.
#   --bmc <host>        Use this BMC address instead of the internal link.
#   --no-bmc            Part A only, skip the BIOS read entirely.
#   --stage enable|disable  After the check, run tdx-bios-set.sh with that
#                       action. It checks the request against the firmware
#                       registry and asks before sending. Default: none.
#   --reboot            With --stage: offer a graceful restart afterwards.
#   --ref <git ref>     Branch, tag or commit to fetch from. Default main.
#   --local             Use tdx-host-check.sh and tdx-bios-set.sh from the
#                       directory this file is in, fetch nothing.
#   --out <dir>         Where the zips go. Default /tmp/tdx-host-check-<date>.
#   --label <text>      Passed to the check, e.g. before or after.
#   --yes, -y           Answer yes to every question in every script.
#   -h, --help          This text.
#
# Needs root for the full check and for the internal link. Everything the
# scripts produce ends up in one folder, printed at the end, and the
# credentials never leave the auth file or the process environment.
#
# Author: Simon Janeck. MIT licence, see LICENSE in the repository.

set -u
REPO_RAW="https://raw.githubusercontent.com/simonjaneck/scripts"
REF="main"; BMC_USER=""; AUTH=""; SAVE=1; BMC="internal"; STAGE=""; REBOOT=0; LOCAL=0; OUT=""; LABEL=""; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bmc-user) BMC_USER="$2"; shift 2;;
    --auth-file) AUTH="$2"; shift 2;;
    --no-save) SAVE=0; shift;;
    --bmc) BMC="$2"; shift 2;;
    --no-bmc) BMC=""; shift;;
    --stage) STAGE="$2"; shift 2;;
    --reboot) REBOOT=1; shift;;
    --ref) REF="$2"; shift 2;;
    --local) LOCAL=1; shift;;
    --out) OUT="$2"; shift 2;;
    --label) LABEL="$2"; shift 2;;
    --yes|-y) YES=1; shift;;
    -h|--help) sed -n '2,36p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
case "$STAGE" in ""|enable|disable) ;; *) echo "--stage takes enable or disable" >&2; exit 2;; esac

ask() { local a; read -r -p "$1" a </dev/tty; printf '%s' "$a"; }
asks() { local a; read -r -s -p "$1" a </dev/tty; echo >/dev/tty; printf '%s' "$a"; }
yn() { [ "$YES" = 1 ] && return 0; local a; a=$(ask "$1 [Y/n] "); case "$a" in n|N|no|NO) return 1;; *) return 0;; esac; }

[ -n "$OUT" ] || OUT="/tmp/tdx-host-check-$(date -u +%Y%m%d)"
mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 1; }
cd "$OUT" || exit 1
echo "working in $OUT"
[ "$(id -u)" -eq 0 ] || echo "note: not root. The check will be incomplete and the internal BMC link cannot be configured. Prefer: curl ... | sudo bash"

# ------------------------------------------------------------- fetch
if [ "$LOCAL" = 1 ]; then
  SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  for f in tdx-host-check.sh tdx-bios-set.sh; do
    [ -r "$SRC/$f" ] || { echo "--local given but $SRC/$f not found" >&2; exit 1; }
    cp "$SRC/$f" "$OUT/$f"
  done
  echo "using local copies from $SRC"
else
  for f in tdx-host-check.sh tdx-bios-set.sh; do
    url="$REPO_RAW/$REF/tdx-host-check/$f"
    if command -v curl >/dev/null; then curl -fsSL "$url" -o "$OUT/$f"; else wget -q "$url" -O "$OUT/$f"; fi \
      || { echo "could not fetch $url. No route to the internet? Copy the two scripts here and use --local." >&2; exit 1; }
    head -1 "$OUT/$f" | grep -q '^#!' || { echo "$f did not download as a script, check the ref $REF" >&2; exit 1; }
  done
  echo "fetched tdx-host-check.sh and tdx-bios-set.sh at ref $REF"
  sha256sum "$OUT/tdx-host-check.sh" "$OUT/tdx-bios-set.sh" | sed 's/^/  /'
fi
chmod +x "$OUT/tdx-host-check.sh" "$OUT/tdx-bios-set.sh"

# ------------------------------------------------------- credentials
AUTHARG=()
if [ -n "$BMC" ]; then
  [ -z "$AUTH" ] && [ -r "$HOME/.tdx-bmc.auth" ] && AUTH="$HOME/.tdx-bmc.auth"
  if [ -n "$AUTH" ] && [ -r "$AUTH" ]; then
    echo "BMC login from $AUTH"
    AUTHARG=(--auth-file "$AUTH")
  else
    echo "No BMC auth file. The BIOS read needs a BMC account with read access."
    [ -n "$BMC_USER" ] || BMC_USER=$(ask "BMC user: ")
    BMC_PASS=$(asks "BMC password: ")
    if [ -z "$BMC_USER" ] || [ -z "$BMC_PASS" ]; then
      echo "no BMC login given, running part A only"; BMC=""
    else
      export BMC_PASS
      if [ "$SAVE" = 1 ] && yn "Save this login to $HOME/.tdx-bmc.auth (mode 600) for the next run?"; then
        umask 077; printf 'USERNAME=%s\nPASSWORD=%s\n' "$BMC_USER" "$BMC_PASS" >"$HOME/.tdx-bmc.auth" && chmod 600 "$HOME/.tdx-bmc.auth"
        AUTH="$HOME/.tdx-bmc.auth"; AUTHARG=(--auth-file "$AUTH"); echo "saved"
      fi
    fi
  fi
fi

# ------------------------------------------------------------- check
echo; echo "===== 1. read-only check ====="
CHK=(./tdx-host-check.sh --out "$OUT")
[ -n "$BMC" ] && CHK+=(--bmc "$BMC")
[ -n "$BMC" ] && [ ${#AUTHARG[@]} -eq 0 ] && [ -n "$BMC_USER" ] && CHK+=(--bmc-user "$BMC_USER")
[ ${#AUTHARG[@]} -gt 0 ] && CHK+=("${AUTHARG[@]}")
[ -n "$LABEL" ] && CHK+=(--label "$LABEL")
[ "$YES" = 1 ] && CHK+=(--yes)
"${CHK[@]}"; RC=$?
[ "$RC" = 0 ] || echo "the check exited with $RC, continuing with what there is"

# ------------------------------------------------------- BIOS settings
if [ -n "$BMC" ]; then
  echo; echo "===== 2. BIOS settings, current and pending, read-only ====="
  SET=(./tdx-bios-set.sh --bmc "$BMC" --out "$OUT" --show)
  [ ${#AUTHARG[@]} -gt 0 ] && SET+=("${AUTHARG[@]}")
  [ ${#AUTHARG[@]} -eq 0 ] && [ -n "$BMC_USER" ] && SET+=(--bmc-user "$BMC_USER")
  [ "$YES" = 1 ] && SET+=(--yes)
  "${SET[@]}" || echo "could not read the BIOS settings, see above"
fi

# ------------------------------------------------------------- stage
if [ -n "$STAGE" ] && [ -n "$BMC" ]; then
  echo; echo "===== 3. stage BIOS settings: $STAGE ====="
  echo "tdx-bios-set.sh checks the request against the firmware's registry first and asks before sending."
  SET=(./tdx-bios-set.sh --bmc "$BMC" --out "$OUT" "--$STAGE")
  [ ${#AUTHARG[@]} -gt 0 ] && SET+=("${AUTHARG[@]}")
  [ ${#AUTHARG[@]} -eq 0 ] && [ -n "$BMC_USER" ] && SET+=(--bmc-user "$BMC_USER")
  [ "$REBOOT" = 1 ] && SET+=(--reboot)
  [ "$YES" = 1 ] && SET+=(--yes)
  "${SET[@]}" || echo "staging did not complete, see above. Nothing is applied until a reboot anyway."
elif [ -n "$STAGE" ]; then
  echo "cannot stage without a BMC connection"
fi

unset BMC_PASS
echo; echo "===== done ====="
echo "everything is in $OUT:"
ls -1 "$OUT"/*.zip 2>/dev/null | sed 's/^/  /'
echo "send the zip files."
