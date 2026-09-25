#!/usr/bin/env bash
# deploy/tests/test_admin_cidr.sh: the interview asks who may reach the
# appliances, and refuses to accept anything that is not an IPv4 CIDR or the
# NSG's "*" (anywhere).
#
# Why this exists. The three Marketplace templates carry an adminSourceCidr
# parameter whose default is "*", and until this question existed nothing
# in deploy-stack.sh ever supplied it, so every run opened SSH (22), vPB SSH
# (9022) and HTTPS (443) to the internet. That is the first thing a corporate
# CIS scan reports, and the AWS deploy script had already grown the question,
# so the two clouds disagreed.
#
# Hermetic: no Azure, no network. `ask` and `curl` are stubs per case, so the
# public-IP lookup never leaves the machine.
#
# Usage: bash deploy/tests/test_admin_cidr.sh
#        DEPLOY_STACK_SH=/path/to/deploy-stack.sh bash deploy/tests/test_admin_cidr.sh
set -u
cd "$(dirname "$0")/../.."
SCRIPT="${DEPLOY_STACK_SH:-deploy/deploy-stack.sh}"
S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT

# Lift only the functions under test plus the one-line output helpers they
# call. Functions must be written `name() {` at column 0 with the closing `}`
# at column 0 for this to find their end.
awk '
  /^(ok|warn|fail|step|note)\(\)/ { print; next }
  /^(valid_cidr|ask_admin_cidr)\(\)/ { p=1 }
  p { print }
  p && /^}/ { p=0 }
' "$SCRIPT" > "$S/helpers.sh"

PASS=0; FAIL=0
ok_()  { echo "PASS $*"; PASS=$((PASS+1)); }
bad_() { echo "FAIL $*"; FAIL=$((FAIL+1)); }

if ! grep -q '^ask_admin_cidr()' "$S/helpers.sh" || ! grep -q '^valid_cidr()' "$S/helpers.sh"; then
  echo "FAIL the interview has no admin CIDR question (ask_admin_cidr/valid_cidr missing)"
  echo; echo "0 PASS, 1 FAIL"; exit 1
fi

# run "<detected public ip or empty>" "<answer>[|<answer>...]" [first-lookup-fails]
# Echoes the chosen CIDR on stdout; the prompts and warnings land in $S/err.
# With a third argument, the first lookup endpoint (ipify) fails and only the
# second (checkip) answers, which is how the fallback is exercised.
run() {
  local detected="$1" answers="$2" mode="${3:-}"
  /bin/bash -c '
    set -euo pipefail
    C_GREEN= C_YELLOW= C_BLUE= C_RED= C_GREY= C_BOLD= C_RESET=
    DETECTED="$1"; ANSWERS="$2"; MODE="$5"
    # Public-IP lookup, stubbed: an empty DETECTED plays both endpoints
    # failing; MODE set plays only the first endpoint failing.
    curl() {
      [ -n "$DETECTED" ] || return 1
      if [ -n "$MODE" ]; then
        case "$*" in *api.ipify.org*) return 1 ;; esac
      fi
      printf "%s\n" "$DETECTED"
    }
    # ask pops the next queued answer; an empty one means the operator pressed
    # Enter, which must yield the default the prompt offered.
    # The real ask reads the terminal afresh each call. Every call here is a
    # command substitution, so a shell variable would never advance: the queue
    # lives in a file.
    printf "%s" "$ANSWERS" > "$4"
    ask() {
      local def="${2:-}" q a
      q="$(cat "$QUEUE")"
      a="${q%%|*}"
      case "$q" in *"|"*) printf "%s" "${q#*|}" > "$QUEUE" ;; *) : > "$QUEUE" ;; esac
      printf "%s" "${a:-$def}"
    }
    QUEUE="$4"
    source "$3"
    ask_admin_cidr
  ' _ "$detected" "$answers" "$S/helpers.sh" "$S/queue" "$mode" 2>"$S/err"
}

# 1. the operator types their corporate range
got="$(run "203.0.113.10" "10.0.0.0/8")"
if [ "$got" = "10.0.0.0/8" ]; then ok_ "1. a typed CIDR is used as given"; else bad_ "1. expected 10.0.0.0/8, got '$got'"; fi

# 2. the detected public address is offered as the default and Enter takes it
got="$(run "203.0.113.10" "")"
if [ "$got" = "203.0.113.10/32" ]; then ok_ "2. Enter takes this machine's address as a /32"; else bad_ "2. expected 203.0.113.10/32, got '$got'"; fi
if grep -q "203.0.113.10" "$S/err"; then ok_ "2b. the offered default is shown to the operator"; else bad_ "2b. the detected address was never shown"; fi
if grep -q "9022" "$S/err" && grep -q "VXLAN" "$S/err"; then ok_ "2c. the prompt names the Azure ports and says VXLAN is handled separately"; else bad_ "2c. the prompt does not name the ports it governs"; fi

# 3. junk is refused and the question repeats
got="$(run "203.0.113.10" "not-a-cidr|10.1.2.0/24")"
if [ "$got" = "10.1.2.0/24" ]; then ok_ "3. an invalid answer is refused and the question repeats"; else bad_ "3. expected 10.1.2.0/24, got '$got'"; fi
if grep -q "is not an IPv4 CIDR" "$S/err"; then ok_ "3b. the operator is told why it was refused"; else bad_ "3b. no reason was given"; fi

# 4. a prefix out of range and a bad octet are both refused
got="$(run "" "10.0.0.0/33|300.1.1.1/24|172.16.0.0/12")"
if [ "$got" = "172.16.0.0/12" ]; then ok_ "4. /33 and a 300 octet are both refused"; else bad_ "4. expected 172.16.0.0/12, got '$got'"; fi

# 5. opening it to the world is allowed but warned about, in both spellings
got="$(run "203.0.113.10" "*")"
if [ "$got" = "*" ]; then ok_ "5. * is accepted when asked for"; else bad_ "5. expected *, got '$got'"; fi
if grep -q "reachable from any address on the internet" "$S/err"; then ok_ "5b. choosing * warns"; else bad_ "5b. no warning for *"; fi
got="$(run "203.0.113.10" "0.0.0.0/0")"
if [ "$got" = "*" ]; then ok_ "5c. 0.0.0.0/0 is accepted and mapped to * (what the NSG expects)"; else bad_ "5c. expected * for 0.0.0.0/0, got '$got'"; fi
if grep -q "reachable from any address on the internet" "$S/err"; then ok_ "5d. choosing 0.0.0.0/0 warns"; else bad_ "5d. no warning for 0.0.0.0/0"; fi

# 6. no public address available: the default becomes * and says so
got="$(run "" "")"
if [ "$got" = "*" ]; then ok_ "6. a failed lookup falls back to *"; else bad_ "6. expected *, got '$got'"; fi
if grep -q "could not be read" "$S/err"; then ok_ "6b. the operator is told the lookup failed"; else bad_ "6b. the failed lookup was silent"; fi
if grep -q "reachable from any address on the internet" "$S/err"; then ok_ "6c. falling back to * warns"; else bad_ "6c. the * fallback was silent"; fi

# 7. three bad answers stop the loop instead of asking forever
got="$(run "203.0.113.10" "x|y|z|10.0.0.0/8")"
if [ "$got" = "203.0.113.10/32" ]; then ok_ "7. three invalid answers fall back to the default, no endless loop"; else bad_ "7. expected the default after 3 tries, got '$got'"; fi

# 8. valid_cidr itself, the edges. "*" is deliberately refused here: the
# interview recognises it before consulting valid_cidr, which stays strict.
edge() {
  /bin/bash -c 'set -uo pipefail; source "$1"; if valid_cidr "$2"; then echo yes; else echo no; fi' _ "$S/helpers.sh" "$1" 2>/dev/null
}
bad_edges=0
for c in "1.2.3.4" "10.0.0.0/8/8" "10.0.0/8" "" "10.0.0.0/-1" "abc/24" "*" "10.0.0.0/8 "; do
  [ "$(edge "$c")" = "no" ] || { bad_edges=$((bad_edges+1)); echo "    ('$c' was accepted)"; }
done
for c in "0.0.0.0/0" "255.255.255.255/32" "10.0.0.0/8"; do
  [ "$(edge "$c")" = "yes" ] || { bad_edges=$((bad_edges+1)); echo "    ('$c' was refused)"; }
done
if [ "$bad_edges" -eq 0 ]; then ok_ "8. valid_cidr accepts real CIDRs and refuses malformed ones"; else bad_ "8. valid_cidr got $bad_edges edge cases wrong"; fi

# 9. the second lookup endpoint is used when the first one is down
got="$(run "198.51.100.7" "" "first-fails")"
if [ "$got" = "198.51.100.7/32" ]; then ok_ "9. the checkip fallback is used when ipify fails"; else bad_ "9. expected 198.51.100.7/32 from the fallback endpoint, got '$got'"; fi

echo
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
