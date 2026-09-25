#!/usr/bin/env bash
# Phase 10 of deploy-stack.sh: the project key.
#
# The script creates the vController project automatically (the same way the
# AWS repo does), but it used to print the manual steps anyway, discard that
# key and prompt for a paste, so a run that could be fully automatic always
# stopped. This runs the real Phase 10 block with stubs and checks that the
# paste happens only when the automatic step fails.
#
# DEPLOY_STACK_SH points at another copy of the script: that is how the test
# is proven to go red against the version before the fix.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${DEPLOY_STACK_SH:-$HERE/../deploy-stack.sh}"
PASS=0; FAIL=0
pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

awk '/^step "Phase 10:/{on=1} /^# Phase 11:/{on=0} on' "$SCRIPT" > "$T/phase10.sh"
[[ -s "$T/phase10.sh" ]] || { echo "could not extract Phase 10"; exit 1; }
mkdir -p "$T/bin"
printf '#!/bin/sh\necho 3\n' > "$T/bin/az"; chmod +x "$T/bin/az"

run_case() {  # $1 = key the automatic step returns ("" = it fails), $2 = stdin
  printf 'print("%s") if "%s" else None\n' "$1" "$1" > "$T/pk.py"
  cat > "$T/run.sh" <<RUN
step() { :; }; note() { :; }; dryrun_say() { :; }
ok() { echo "OK: \$*"; }; warn() { echo "WARN: \$*"; }
py_ready() { return 0; }; find_script() { echo "$T/pk.py"; }
RESOURCE_GROUP=rg; ADMIN_PASSWORD=pw; DRY_RUN=false; CLMS_PUBLIC_IP=192.0.2.10
CHAIN_SENSORS=true; DISCOVERY_TAG_KEY=cloudlens; DISCOVERY_TAG_VALUE=yes; HOME="$T"
source "$T/phase10.sh"
echo "RESULT key=[\$PROJECT_KEY] chain=[\$CHAIN_SENSORS]"
RUN
  printf '%s\n' "$2" | PATH="$T/bin:$PATH" bash "$T/run.sh" 2>&1
}

out="$(run_case AUTOKEY123 SHOULD-NOT-BE-READ)"
if grep -q 'RESULT key=\[AUTOKEY123\] chain=\[true\]' <<<"$out"; then pass "automatic key is used; nothing is read from the terminal"
else fail "automatic key was discarded or a paste was read: $(grep RESULT <<<"$out")"; fi
if grep -q 'Open the vController UI' <<<"$out"; then fail "manual steps printed although the key was created automatically"
else pass "no manual steps printed when the automatic step works"; fi

out="$(run_case "" MANUALKEY9)"
if grep -q 'RESULT key=\[MANUALKEY9\] chain=\[true\]' <<<"$out" && grep -q 'Open the vController UI' <<<"$out"; then
  pass "falls back to the manual steps and a paste when the automatic step fails"
else fail "manual fallback broken: $(grep RESULT <<<"$out")"; fi

out="$(run_case "" "")"
if grep -q 'chain=\[false\]' <<<"$out"; then pass "no key at all skips the sensor chain cleanly"
else fail "an empty paste did not skip the sensor chain: $(grep RESULT <<<"$out")"; fi

printf '\n%d PASS, %d FAIL\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
