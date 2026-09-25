#!/usr/bin/env bash
# Static checks on the Azure ARM templates behind the portal buttons and
# deploy/deploy-stack.sh. They guard two fixes that are easy to lose in a
# hand edit: admin ports must not be open to the internet by default-of-
# laziness (every 22/9022/443 rule takes its source from adminSourceCidr,
# the VXLAN rules from sensorSourcePrefix), and every VM-owned resource
# carries deleteOption=Delete so deleting a VM does not strand its disk,
# NICs and public IP and keep billing.
#
# Usage: bash deploy/tests/test_templates.sh
#        TEMPLATE_DIR=/tmp/old bash deploy/tests/test_templates.sh
#
# TEMPLATE_DIR points the suite at another copy of the templates, which is
# how you prove it goes red against the pre-fix files. Needs only bash 3.2
# and python3 with the standard library.
set -uo pipefail

cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 1

TEMPLATE_DIR="${TEMPLATE_DIR:-deploy}"
export TEMPLATE_DIR

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# The checker writes one "PASS<TAB>msg" or "FAIL<TAB>msg" line per check.
# Results go through a file rather than a pipe so the counters stay in this
# shell (a pipe would run the read loop in a subshell and lose them).
RESULTS="$(mktemp -t test_templates.XXXXXX)" || exit 1
trap 'rm -f "$RESULTS"' EXIT

python3 - > "$RESULTS" <<'PYEOF'
import json
import os
import re
import sys

TDIR = os.environ.get("TEMPLATE_DIR", "deploy")

ADMIN_PORTS = {"22", "9022", "443"}
SENSOR_PORTS = {"4789", "10800-10801"}
ADMIN_REF = "parameters('adminSourceCidr')"
SENSOR_REF = "parameters('sensorSourcePrefix')"

# Ports each product's NSG must actually carry, so a template that silently
# dropped a rule cannot pass by having nothing left to check.
PRODUCTS = {
    "clms-marketplace.json": {"admin": {"22", "443"}, "sensor": set()},
    "kvo-marketplace.json": {"admin": {"22", "443"}, "sensor": set()},
    "vpb-marketplace.json": {"admin": {"22", "9022", "443"}, "sensor": SENSOR_PORTS},
}
STACK = "stack-marketplace.json"
UI_FILES = {
    "clms-createUiDefinition.json": False,
    "kvo-createUiDefinition.json": False,
    "vpb-createUiDefinition.json": True,
    "stack-createUiDefinition.json": True,
}


def report(ok, fname, what, detail=""):
    line = "%s\t%s: %s" % ("PASS" if ok else "FAIL", fname, what)
    if not ok and detail:
        line += " (%s)" % detail
    sys.stdout.write(line + "\n")
    return ok


def load(fname):
    path = os.path.join(TDIR, fname)
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        report(False, fname, "parses as JSON", str(exc))
        return None
    report(True, fname, "parses as JSON")
    return doc


def resources(doc, rtype):
    return [r for r in doc.get("resources", []) if r.get("type") == rtype]


def nsg_rules(doc):
    rules = []
    for nsg in resources(doc, "Microsoft.Network/networkSecurityGroups"):
        for rule in nsg.get("properties", {}).get("securityRules", []):
            props = rule.get("properties", {})
            ports = set()
            if "destinationPortRange" in props:
                ports.add(str(props["destinationPortRange"]))
            for p in props.get("destinationPortRanges", []) or []:
                ports.add(str(p))
            rules.append((rule.get("name", "?"), ports, str(props.get("sourceAddressPrefix", ""))))
    return rules


def check_sources(fname, rules, ports, ref, label):
    missing = sorted(p for p in ports if not any(p in rp for _, rp, _ in rules))
    bad = []
    for name, rp, src in rules:
        if not (rp & ports):
            continue
        if src.strip() == "*" or ref not in src:
            bad.append("%s source=%r" % (name, src))
    detail = "; ".join(
        (["no rule on port(s) %s" % ", ".join(missing)] if missing else []) + bad)
    return report(not missing and not bad, fname, label, detail)


def leaf_nic_vars(expr, variables, seen):
    # The vPB builds its VM NIC list from variables that nest other variables;
    # walk them down to the ones that hold the literal NIC JSON.
    for name in re.findall(r"variables\('([^']+)'\)", expr):
        if name in seen:
            continue
        seen.add(name)
        val = variables.get(name)
        if isinstance(val, str) and "variables('" in val:
            leaf_nic_vars(val, variables, seen)
    return seen


def check_product(fname, spec):
    doc = load(fname)
    if doc is None:
        return
    params = doc.get("parameters", {})
    report("adminSourceCidr" in params, fname, "parameter adminSourceCidr exists")
    if spec["sensor"]:
        report("sensorSourcePrefix" in params, fname, "parameter sensorSourcePrefix exists")

    rules = nsg_rules(doc)
    check_sources(fname, rules, spec["admin"], ADMIN_REF,
                  "NSG rules on 22/9022/443 take their source from adminSourceCidr")
    if spec["sensor"]:
        check_sources(fname, rules, spec["sensor"], SENSOR_REF,
                      "NSG rules on 4789/10800-10801 take their source from sensorSourcePrefix")
    stars = [name for name, _, src in rules if src.strip() == "*"]
    report(not stars, fname, "no NSG rule keeps a literal * source", ", ".join(stars))

    vms = resources(doc, "Microsoft.Compute/virtualMachines")
    if not report(len(vms) == 1, fname, "exactly one virtualMachines resource", "found %d" % len(vms)):
        return
    vm = vms[0]
    vm_props = vm.get("properties", {})
    os_disk = vm_props.get("storageProfile", {}).get("osDisk", {})
    report(os_disk.get("deleteOption") == "Delete", fname, "osDisk deleteOption is Delete",
           "got %r" % os_disk.get("deleteOption"))

    nics = vm_props.get("networkProfile", {}).get("networkInterfaces")
    bad = []
    count = 0
    if isinstance(nics, list):
        for entry in nics:
            count += 1
            if entry.get("properties", {}).get("deleteOption") != "Delete":
                bad.append(entry.get("id", "?"))
    elif isinstance(nics, str):
        variables = doc.get("variables", {})
        for name in sorted(leaf_nic_vars(nics, variables, set())):
            val = variables.get(name)
            if not isinstance(val, str) or "Microsoft.Network/networkInterfaces" not in val:
                continue
            count += 1
            if not re.search(r'"deleteOption"\s*:\s*"Delete"', val):
                bad.append("variables('%s')" % name)
    report(count > 0 and not bad, fname, "every VM NIC entry has deleteOption Delete",
           "no NIC entries found" if count == 0 else ", ".join(bad))

    bad = []
    count = 0
    for nic in resources(doc, "Microsoft.Network/networkInterfaces"):
        for ipc in nic.get("properties", {}).get("ipConfigurations", []):
            pip = ipc.get("properties", {}).get("publicIPAddress")
            if not pip:
                continue
            count += 1
            if pip.get("properties", {}).get("deleteOption") != "Delete":
                bad.append("%s/%s" % (nic.get("name", "?"), ipc.get("name", "?")))
    report(count > 0 and not bad, fname, "every NIC public IP has deleteOption Delete",
           "no public IP references found" if count == 0 else ", ".join(bad))

    for r in vms + resources(doc, "Microsoft.Network/networkInterfaces"):
        # deleteOption only exists in these API versions or later; an older
        # apiVersion would make Azure reject the property outright.
        report(str(r.get("apiVersion", "")) >= "2021-03-01", fname,
               "%s apiVersion supports deleteOption" % r["type"].split("/")[-1],
               "got %r" % r.get("apiVersion"))


def check_stack():
    doc = load(STACK)
    if doc is None:
        return
    params = doc.get("parameters", {})
    report("adminSourceCidr" in params, STACK, "parameter adminSourceCidr exists")
    report("sensorSourcePrefix" in params, STACK, "parameter sensorSourcePrefix exists")

    deployments = resources(doc, "Microsoft.Resources/deployments")
    bad = []
    vpb_seen = False
    for dep in deployments:
        props = dep.get("properties", {})
        uri = str(props.get("templateLink", {}).get("uri", ""))
        passed = props.get("parameters", {})
        name = dep.get("name", "?")
        if ADMIN_REF not in str(passed.get("adminSourceCidr", {}).get("value", "")):
            bad.append("%s lacks adminSourceCidr" % name)
        if "vpb-marketplace.json" in uri:
            vpb_seen = True
            if SENSOR_REF not in str(passed.get("sensorSourcePrefix", {}).get("value", "")):
                bad.append("%s lacks sensorSourcePrefix" % name)
    report(len(deployments) >= 3, STACK, "links the three product templates",
           "found %d linked deployments" % len(deployments))
    report(vpb_seen and not bad, STACK, "every linked deployment passes the source parameters through",
           "no vPB deployment found" if not vpb_seen else "; ".join(bad))


def find_elements(node, found):
    if isinstance(node, dict):
        if node.get("name") == "adminSourceCidr" and "type" in node:
            found.append(node)
        for v in node.values():
            find_elements(v, found)
    elif isinstance(node, list):
        for v in node:
            find_elements(v, found)
    return found


def check_ui(fname, wants_sensor):
    doc = load(fname)
    if doc is None:
        return
    outputs = doc.get("parameters", {}).get("outputs", {})
    out = str(outputs.get("adminSourceCidr", ""))
    report("steps(" in out and out.endswith(".adminSourceCidr]"), fname,
           "outputs adminSourceCidr from a step control", "got %r" % out)
    boxes = find_elements(doc.get("parameters", {}).get("steps", []), [])
    ok = (len(boxes) == 1 and boxes[0].get("type") == "Microsoft.Common.TextBox"
          and boxes[0].get("constraints", {}).get("required") is True
          and boxes[0].get("constraints", {}).get("regex"))
    report(bool(ok), fname, "has a required adminSourceCidr TextBox with a regex",
           "found %d control(s)" % len(boxes))
    if wants_sensor:
        report(outputs.get("sensorSourcePrefix") == "VirtualNetwork", fname,
               "outputs sensorSourcePrefix VirtualNetwork", "got %r" % outputs.get("sensorSourcePrefix"))


for fname in sorted(PRODUCTS):
    check_product(fname, PRODUCTS[fname])
check_stack()
for fname in sorted(UI_FILES):
    check_ui(fname, UI_FILES[fname])
PYEOF
rc=$?

while IFS=$'\t' read -r status msg; do
  case "$status" in
    PASS) pass "$msg" ;;
    FAIL) fail "$msg" ;;
    *) fail "unrecognised checker output: $status $msg" ;;
  esac
done < "$RESULTS"

if [ "$rc" -ne 0 ]; then
  fail "checker exited with status $rc"
fi

echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
