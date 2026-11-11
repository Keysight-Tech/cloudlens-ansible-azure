#!/usr/bin/env bash
# deploy/tests/test_cyperf.sh: the optional CyPerf traffic generator (--with-cyperf).
#
# Pinned here, because each fails quietly in a live run:
#   1. the option leaks into a deployment that did not ask for it
#   2. the activation code reaches a command line, the log or the summary
#   3. the template loses an output the script reads, or a tag teardown needs
#   4. teardown deletes the group before releasing the CyPerf licence
#
# Hermetic: dry runs only, no Azure call is made.
#
# Usage: bash deploy/tests/test_cyperf.sh
set -u
cd "$(dirname "$0")/../.."
SCRIPT="deploy/deploy-stack.sh"; TEARDOWN="deploy/teardown-stack.sh"; TPL="deploy/cyperf-marketplace.json"
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
PASS=0; FAIL=0
ok_()  { echo "PASS $*"; PASS=$((PASS+1)); }
bad_() { echo "FAIL $*"; FAIL=$((FAIL+1)); }
HERE="$PWD"
dry() { local out="$1"; shift
  ( cd "$S" && /bin/bash "$HERE/$SCRIPT" --dry-run --resource-group cytest --location eastus2 \
      --admin-cidr 198.51.100.7/32 --no-kvo --no-vpb --no-sensors "$@" </dev/null >"$out" 2>&1 ); }

SECRET="ZZZZ-TEST-CODE-9999"
if CLOUDLENS_CYPERF_LICENSE_CODE="$SECRET" dry "$S/on.log" --with-cyperf; then ok_ "dry run with --with-cyperf exits 0"
else bad_ "dry run with --with-cyperf failed: $(tail -3 "$S/on.log")"; fi
grep -q 'Phase 9b: Deploy CyPerf' "$S/on.log" && ok_ "phase 9b launches CyPerf" || bad_ "phase 9b missing"
grep -q 'Phase 13c: CyPerf traffic generator' "$S/on.log" && ok_ "phase 13c configures it" || bad_ "phase 13c missing"
grep -q 'terms accept --publisher keysighttechnologies_cyperf .*controller' "$S/on.log" \
  && grep -q 'terms accept --publisher keysighttechnologies_cyperf .*agent' "$S/on.log" \
  && ok_ "Marketplace terms are accepted for the controller and the agent plan" || bad_ "CyPerf terms not accepted for both plans"
grep -q 'mgmtSubnetName=vcontroller-subnet testSubnetName=vpb-ingress' "$S/on.log" \
  && ok_ "controller and agent management go beside the vController, test interfaces in vpb-ingress" || bad_ "subnet placement changed"
if grep -rq "$SECRET" "$S" 2>/dev/null; then bad_ "the activation code appears in output, log or summary"
else ok_ "the activation code is in no output, log or summary file"; fi
grep -q 'deployRelay=true' "$S/on.log" && ok_ "the relay VM is on by default" || bad_ "the relay is not on by default"
CLOUDLENS_CYPERF_LICENSE_CODE="$SECRET" dry "$S/norelay.log" --with-cyperf --no-cyperf-relay
grep -q 'deployRelay=false' "$S/norelay.log" && ok_ "--no-cyperf-relay turns the relay off" || bad_ "--no-cyperf-relay ignored"
grep -q 'licence supplied' "$S/on.log" && ok_ "the plan says a licence was supplied" || bad_ "plan does not show the licence state"

rm -f "$S"/cloudlens-deploy-* 2>/dev/null
if dry "$S/off.log"; then ok_ "dry run without the option exits 0"; else bad_ "dry run without the option failed"; fi
if grep -i 'cyperf' "$S/off.log" | grep -vq 'Deploy CyPerf: false'; then
  bad_ "a deployment that did not ask for CyPerf acts on it: $(grep -i cyperf "$S/off.log" | grep -v 'Deploy CyPerf: false' | head -2)"
else ok_ "without the option nothing about CyPerf is launched or accepted"; fi
if dry "$S/bad.log" --with-cyperf --cyperf-mbps lots; then bad_ "a non-numeric rate was accepted"
else ok_ "a non-numeric --cyperf-mbps is refused"; fi

python3 - "$TPL" <<'PY' && ok_ "template: valid JSON with the outputs, tags and key-only login the scripts rely on" || bad_ "template check failed"
import json,sys
d=json.load(open(sys.argv[1]))
for o in ("controllerPublicIp","clientControlIp","serverControlIp"): assert o in d["outputs"], o
allvms=[r for r in d["resources"] if r["type"]=="Microsoft.Compute/virtualMachines"]
vms=[r for r in allvms if "plan" in r]            # the three CyPerf appliances
relay=[r for r in allvms if "plan" not in r]      # the optional relay VM
assert len(vms)==3 and len(relay)==1
assert any("cyperf-controller" in r["tags"] for r in vms), "teardown finds the controller by cloudlensRole"
for r in vms:
    assert r["properties"]["osProfile"]["linuxConfiguration"]["disablePasswordAuthentication"] is True
    assert r["properties"]["storageProfile"]["osDisk"]["deleteOption"]=="Delete"
    assert r["plan"]["publisher"]=="keysighttechnologies_cyperf"
rl=relay[0]
assert rl.get("condition")=="[parameters('deployRelay')]", "the relay is optional"
assert "cyperf-relay" in rl["tags"] and "relayTagKey" in rl["tags"], "the relay carries its role and the discovery tag"
cd=rl["properties"]["osProfile"]["customData"]
assert "DNAT" in cd and "MASQUERADE" in cd and "serverTestNic" in cd, "the relay forwards to the server agent"
assert "relayTestIp" in d["outputs"]
assert d["parameters"]["agentAuthPassword"]["type"]=="securestring"
assert d["variables"]["tags"]["deployedBy"]=="cloudlens-stack"
PY

l_rel="$(grep -n '^  release_cyperf_licence$' "$TEARDOWN" | head -1 | cut -d: -f1)"
l_del="$(grep -n '^step "Phase 5: Delete"' "$TEARDOWN" | head -1 | cut -d: -f1)"
[[ -n "$l_rel" && -n "$l_del" && "$l_rel" -lt "$l_del" ]] \
  && ok_ "teardown releases the CyPerf licence before Phase 5 deletes anything" \
  || bad_ "licence release (line ${l_rel:-none}) is not before the delete (line ${l_del:-none})"
grep -q "cloudlensRole=='cyperf-controller'" "$TEARDOWN" && ok_ "teardown finds the controller by its role tag" || bad_ "teardown does not look for the role tag"
grep -q -- '--dut-host "$CYPERF_RELAY_IP"' "$SCRIPT" && ok_ "the test is routed through the relay address" || bad_ "the relay address is not handed to the setup script"
P=playbooks/windows.yaml
l_pull="$(grep -n 'Pull the Windows sensor installer from the vController' "$P" | head -1 | cut -d: -f1)"
l_stop="$(grep -n 'Stop CloudLens service if running' "$P" | head -1 | cut -d: -f1)"
[[ -n "$l_pull" && -n "$l_stop" && "$l_pull" -lt "$l_stop" ]] \
  && ok_ "Windows: the VM pulls the installer from the vController before anything is stopped" \
  || bad_ "Windows pull (line ${l_pull:-none}) is not before the service stop (line ${l_stop:-none})"
grep -A4 'Transfer CloudLens installer from the local file' "$P" | grep -q 'when: not win_installer_pulled' \
  && ok_ "Windows: the copy from this machine is only the fallback" || bad_ "Windows: the local copy is not conditional"
python3 -m py_compile scripts/cyperf_setup.py 2>/dev/null && ok_ "cyperf_setup.py compiles" || bad_ "cyperf_setup.py does not compile"
grep -q -- '--cyperf-license-code' "$SCRIPT" && bad_ "a flag takes the code itself" || ok_ "no flag takes the code itself"
/bin/bash -n "$SCRIPT" && /bin/bash -n "$TEARDOWN" && ok_ "both scripts parse under bash 3.2" || bad_ "syntax error under bash 3.2"

echo; echo "${PASS} PASS, ${FAIL} FAIL"; [[ "$FAIL" -eq 0 ]]
