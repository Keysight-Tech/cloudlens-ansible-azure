#!/usr/bin/env bash
# deploy/tests/test_shared_vnet.sh: the deploy builds ONE virtual network and
# hands it to every appliance, the way the portal's full-stack template does.
#
# Why this exists. Handed no vnetName, each product template makes its own
# VNet. The CLI passed none, so a full deploy came out as three VNets with no
# peering between them: a vController, a KVO and a vPB that could not reach
# each other. The portal form never had the problem because its template
# builds one VNet with five fixed subnets. The CLI now does the same, and this
# suite pins the three ways it settles the network: build it, adopt the
# vController's from an older run, or join the customer's (and never invent
# subnets in that one).
#
# Hermetic: no Azure, no network. `az` is a shell function answering from two
# env lists (STUB_VNETS "name:tag ...", STUB_SUBNETS "vnet/subnet ...") and
# recording every call. Only the functions under test are lifted out of the
# script by awk (written name() { ... } with both braces at column 0).
#
# Usage: bash deploy/tests/test_shared_vnet.sh
#        DEPLOY_STACK_SH=/path/to/deploy-stack.sh bash deploy/tests/test_shared_vnet.sh
set -u
cd "$(dirname "$0")/../.."
SCRIPT="${DEPLOY_STACK_SH:-deploy/deploy-stack.sh}"
S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT

awk '
  /^(subnet_prefix|vnet_exists|vnet_deployed_by|subnet_exists|ensure_shared_vnet)\(\)/ { p=1 }
  p { print }
  p && /^}/ { p=0 }
' "$SCRIPT" > "$S/helpers.sh"

if ! grep -q '^ensure_shared_vnet()' "$S/helpers.sh"; then
  echo "FAIL the deploy has no shared virtual network step (ensure_shared_vnet missing)"
  echo; echo "0 PASS, 1 FAIL"; exit 1
fi

PASS=0; FAIL=0
ok_()  { echo "PASS $*"; PASS=$((PASS+1)); }
bad_() { echo "FAIL $*"; FAIL=$((FAIL+1)); }

# run VARS...: run ensure_shared_vnet under the script's own shell options with
# the given VAR=value pairs in force. Writes $S/out (stdout+stderr), $S/az
# (every az call, one per line) and $S/rc (exit status; fail() exits 9).
run() {
  : > "$S/az"
  /bin/bash -c '
    set -euo pipefail
    AZLOG="$1"; shift
    for kv in "$@"; do export "$kv"; done
    C_GREEN= C_YELLOW= C_BLUE= C_RED= C_GREY= C_BOLD= C_RESET=
    ok()   { echo "[ok] $1"; }
    note() { echo "  -> $1"; }
    warn() { echo "[warn] $1"; }
    fail() { echo "[x] $1" >&2; exit 9; }
    dryrun_say() { echo "[dry-run] $1"; }
    # The stub: STUB_VNETS holds "name:tag" pairs, STUB_SUBNETS "vnet/subnet".
    az() {
      echo "az $*" >> "$AZLOG"
      case "$1 $2 ${3:-}" in
        "network vnet show")
          local n="" q="" a
          for a in "$@"; do :; done
          n="$(printf "%s\n" "$@" | awk "/^-n$/{getline; print; exit}")"
          q="$(printf "%s\n" "$@" | awk "/^--query$/{getline; print; exit}")"
          for v in ${STUB_VNETS:-}; do
            if [[ "${v%%:*}" == "$n" ]]; then
              if [[ "$q" == "tags.deployedBy" ]]; then printf "%s\n" "${v#*:}"; else printf "%s\n" "$n"; fi
              return 0
            fi
          done
          return 3 ;;
        "network vnet subnet")
          local vn="" sn=""
          vn="$(printf "%s\n" "$@" | awk "/^--vnet-name$/{getline; print; exit}")"
          sn="$(printf "%s\n" "$@" | awk "/^-n$/{getline; print; exit}")"
          if [[ "$4" == "show" ]]; then
            for sub in ${STUB_SUBNETS:-}; do
              if [[ "$sub" == "$vn/$sn" ]]; then printf "%s\n" "$sn"; return 0; fi
            done
            return 3
          fi
          return 0 ;;
        *) return 0 ;;
      esac
    }
    source "$HELPERS"
    ensure_shared_vnet
  ' _ "$S/az" "HELPERS=$S/helpers.sh" \
      "RESOURCE_GROUP=rg1" "LOCATION=westeurope" "DRY_RUN=false" \
      "VNET_NAME=" "VNET_RG=" "VNET_CIDR=10.50.0.0/16" "VNET_GIVEN=false" \
      "DEFAULT_VNET_NAME=cloudlens-vnet" "SUBNET_VCONTROLLER=vcontroller-subnet" \
      "SUBNET_KVO=kvo-subnet" "SUBNET_VPB_MGMT=vpb-mgmt" "SUBNET_VPB_INGRESS=vpb-ingress" \
      "SUBNET_VPB_EGRESS=vpb-egress" "VNET_CREATED=false" "VNET_ADOPTED=false" \
      "EXISTING_VCTRL=" "STUB_VNETS=" "STUB_SUBNETS=" "$@" > "$S/out" 2>&1
  echo $? > "$S/rc"
}
rc()       { cat "$S/rc"; }
creates()  { grep -c 'az network vnet create' "$S/az"; }
subnets()  { grep -c 'az network vnet subnet create' "$S/az"; }
az_has()   { grep -q -- "$1" "$S/az"; }
out_has()  { grep -q -- "$1" "$S/out"; }

# 1. nothing exists: build the VNet, tagged, and all five subnets at the portal's prefixes
run
if [[ "$(rc)" == "0" && "$(creates)" == "1" ]] && az_has 'vnet create -g rg1 -n cloudlens-vnet --location westeurope --address-prefixes 10.50.0.0/16 --tags deployedBy=cloudlens-stack'; then
  ok_ "1a. a fresh group gets cloudlens-vnet, tagged deployedBy=cloudlens-stack"
else bad_ "1a. VNet not built as expected (rc=$(rc), creates=$(creates))"; fi
if [[ "$(subnets)" == "5" ]] && az_has 'subnet create -g rg1 --vnet-name cloudlens-vnet -n vcontroller-subnet --address-prefixes 10.50.1.0/24' \
   && az_has -- '-n kvo-subnet --address-prefixes 10.50.2.0/24' && az_has -- '-n vpb-mgmt --address-prefixes 10.50.10.0/24' \
   && az_has -- '-n vpb-ingress --address-prefixes 10.50.11.0/24' && az_has -- '-n vpb-egress --address-prefixes 10.50.12.0/24'; then
  ok_ "1b. five subnets, the portal template's names and prefixes"
else bad_ "1b. subnets wrong: $(subnets) created"; fi

# 2. the VNet from an earlier run (tagged) is missing one subnet: only that one is added
run "STUB_VNETS=cloudlens-vnet:cloudlens-stack" "STUB_SUBNETS=cloudlens-vnet/vcontroller-subnet cloudlens-vnet/vpb-mgmt cloudlens-vnet/vpb-ingress cloudlens-vnet/vpb-egress"
if [[ "$(rc)" == "0" && "$(creates)" == "0" && "$(subnets)" == "1" ]] && az_has -- '-n kvo-subnet --address-prefixes 10.50.2.0/24'; then
  ok_ "2. a VNet this deploy built gets only its missing subnet added"
else bad_ "2. expected exactly one subnet create for kvo-subnet (rc=$(rc), creates=$(creates), subnets=$(subnets))"; fi

# 3. the customer's VNet (--vnet-name) lacks a subnet: named, refused, nothing created
run "VNET_NAME=corp-vnet" "VNET_GIVEN=true" "STUB_VNETS=corp-vnet:" "STUB_SUBNETS=corp-vnet/vcontroller-subnet corp-vnet/kvo-subnet corp-vnet/vpb-mgmt corp-vnet/vpb-ingress"
if [[ "$(rc)" == "9" && "$(creates)" == "0" && "$(subnets)" == "0" ]] && out_has 'vpb-egress' && out_has 'not one this deploy built'; then
  ok_ "3. a customer VNet missing vpb-egress is refused by name, and no subnet is invented"
else bad_ "3. expected a refusal naming vpb-egress with zero creates (rc=$(rc))"; fi

# 4. --vnet-name that does not exist
run "VNET_NAME=ghost-vnet" "VNET_GIVEN=true"
if [[ "$(rc)" == "9" && "$(creates)" == "0" ]] && out_has -- '--vnet-name ghost-vnet does not exist'; then
  ok_ "4. a --vnet-name that does not exist stops the run instead of being built"
else bad_ "4. expected a clear stop for a missing --vnet-name (rc=$(rc), creates=$(creates))"; fi

# 5. adopt: a vController from before this step built old-clms-vnet; the KVO and vPB join it
run "EXISTING_VCTRL=old-clms" "STUB_VNETS=old-clms-vnet:" "STUB_SUBNETS=old-clms-vnet/vcontroller-subnet"
if [[ "$(rc)" == "0" && "$(creates)" == "0" && "$(subnets)" == "4" ]] && out_has 'old-clms-vnet' && out_has 'adopted' && az_has -- '--vnet-name old-clms-vnet -n kvo-subnet'; then
  ok_ "5. an existing vController's VNet is adopted and the four missing subnets are added to it"
else bad_ "5. adoption failed (rc=$(rc), creates=$(creates), subnets=$(subnets))"; fi

# 6. dry run: nothing asked of Azure, every create echoed
run "DRY_RUN=true"
if [[ "$(rc)" == "0" && ! -s "$S/az" ]] && [[ "$(grep -c '^\[dry-run\] az network vnet' "$S/out")" == "6" ]]; then
  ok_ "6. a dry run calls az zero times and echoes the six creates"
else bad_ "6. dry run touched az or did not echo the creates (rc=$(rc), az lines=$(wc -l < "$S/az" | tr -d ' '))"; fi

# 7. a different /16 carves the same slots
run "VNET_CIDR=10.60.0.0/16"
if az_has -- '--address-prefixes 10.60.0.0/16' && az_has -- '-n vpb-egress --address-prefixes 10.60.12.0/24' && az_has -- '-n vcontroller-subnet --address-prefixes 10.60.1.0/24'; then
  ok_ "7. --vnet-cidr 10.60.0.0/16 gives 10.60.1/2/10/11/12.0/24"
else bad_ "7. subnet prefixes did not follow the /16"; fi

# 8. a hand-made VNet with the default name, untagged: not ours, subnets are never invented
run "STUB_VNETS=cloudlens-vnet:" "STUB_SUBNETS=cloudlens-vnet/vcontroller-subnet"
if [[ "$(rc)" == "9" && "$(subnets)" == "0" ]] && out_has 'kvo-subnet vpb-mgmt vpb-ingress vpb-egress'; then
  ok_ "8. an untagged VNet the deploy did not build is not modified, and every missing subnet is named"
else bad_ "8. expected a refusal listing four subnets (rc=$(rc), subnets=$(subnets))"; fi

# 9. end to end, dry run of the whole script: every appliance is handed the one VNet
export PATH="$S:$PATH"
cat > "$S/az" <<'EOF'
#!/usr/bin/env bash
echo '[]'
EOF
chmod +x "$S/az"
CLOUDLENS_RG=e2e-rg CLOUDLENS_REGION=westeurope CLOUDLENS_ADMIN_CIDR=203.0.113.10/32 \
  bash "$SCRIPT" --dry-run --with-kvo --with-vpb --no-sensors </dev/null > "$S/e2e.out" 2>&1
e2e_rc=$?
n_vnet="$(grep -c 'deployment group create.*vnetName=cloudlens-vnet' "$S/e2e.out")"
if [[ "$e2e_rc" == "0" && "$n_vnet" == "3" ]] && grep -q 'clms-marketplace.json.*subnetName=vcontroller-subnet' "$S/e2e.out" \
   && grep -q 'kvo-marketplace.json.*subnetName=kvo-subnet' "$S/e2e.out" && [[ "$(grep -c 'network vnet create' "$S/e2e.out")" == "1" ]]; then
  ok_ "9. a full dry run builds one VNet and hands it to all three deployments"
else bad_ "9. end to end: rc=$e2e_rc, deployments with the VNet=$n_vnet"; fi

echo
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
