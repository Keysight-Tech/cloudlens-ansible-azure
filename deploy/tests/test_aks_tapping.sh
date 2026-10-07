#!/usr/bin/env bash
# deploy/tests/test_aks_tapping.sh: Phase 13b, AKS pod tapping, from the
# deploy's side of its contract with scripts/deploy-aks-tapping.sh.
#
# Why this exists. The engine's command line is fixed and two authors build
# to it, so the deploy must hand it exactly the flags it expects, with the
# three inputs only the deploy knows settled correctly: the project key (the
# KVO Kubernetes presence's own key when there is a KVO, else Phase 10's),
# the address the pods register on (the vController's PRIVATE address when
# the cluster shares the VNet, since Azure SNATs VNet-to-public traffic and
# the NSG refuses it; the public one otherwise), and the subnet the sample
# cluster's nodes join. Getting the key wrong puts the pods under the VM
# sensors' project where the pod collection selects nothing; getting the
# address wrong fails registration on every node. Both were seen live on
# the AWS rail, and this suite pins the Azure port before it is run live.
#
# Hermetic: no Azure, no network. `az` is an exported shell function that
# answers '[]' to everything except `aks show`, which returns
# STUB_AKS_SUBNET_ID so the address choice can be driven from the suite.
# Every check runs the whole deploy in --dry-run with no terminal, from a
# scratch cwd: a dry run writes its log and summary into the working
# directory, and the repo root is not the place for them.
#
# Usage: bash deploy/tests/test_aks_tapping.sh
#        DEPLOY_STACK_SH=/path/to/deploy-stack.sh bash deploy/tests/test_aks_tapping.sh
set -u
cd "$(dirname "$0")/../.."
REPO="$(pwd)"
SCRIPT="${DEPLOY_STACK_SH:-$REPO/deploy/deploy-stack.sh}"
S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT

PASS=0; FAIL=0
ok_()  { echo "PASS $*"; PASS=$((PASS+1)); }
bad_() { echo "FAIL $*"; FAIL=$((FAIL+1)); }

# The stub is an exported FUNCTION, not a file on PATH. Phase 2 of the deploy
# force-prepends Homebrew's bin directory on macOS to route around a pyenv
# shim, which puts a real az in front of any stub file; a function inherited
# through the environment wins over every PATH entry. `aks show` answers with
# the first node pool's subnet id, which the suite sets; everything else gets
# an empty JSON list.
az() {
  if [[ "${1:-}" == "aks" && "${2:-}" == "show" ]]; then
    printf '%s\n' "${STUB_AKS_SUBNET_ID:-}"
    return 0
  fi
  echo '[]'
}
export -f az

# run FLAGS...: one full dry run with the flags given and no terminal. Writes
# $S/out (stdout+stderr), $S/rc (exit status) and the deploy's own summary
# file under $S/cwd. Env vars for the deploy are exported by the caller.
run() {
  rm -rf "$S/cwd"; mkdir -p "$S/cwd"
  ( cd "$S/cwd" && CLOUDLENS_RG=aks-rg CLOUDLENS_REGION=westeurope \
      CLOUDLENS_ADMIN_CIDR=203.0.113.10/32 \
      bash "$SCRIPT" --dry-run --no-sensors "$@" </dev/null ) > "$S/out" 2>&1
  echo $? > "$S/rc"
  # The deploy tees its own output (exec > >(tee ...)), and that tee keeps
  # writing after bash has exited, so the file is read only once it has
  # stopped growing: two polls 0.1s apart agreeing, within five seconds.
  local prev=-1 size=0 i=0
  while [[ $i -lt 50 ]]; do
    size="$(wc -c < "$S/out" | tr -d ' ')"
    if [[ "$size" == "$prev" ]]; then break; fi
    prev="$size"; sleep 0.1; i=$((i+1))
  done
}
rc()       { cat "$S/rc"; }
out_has()  { grep -q -- "$1" "$S/out"; }
out_line() { grep -n -- "$1" "$S/out" | head -1 | cut -d: -f1; }
# The two dry-run command lines Phase 13b prints.
kvo_cmd()    { grep -- 'kvo_k8s_config.py' "$S/out" | head -1; }
engine_cmd() { grep -- 'bash scripts/deploy-aks-tapping.sh' "$S/out" | head -1; }

# 0. the script parses
if bash -n "$SCRIPT"; then ok_ "0. deploy-stack.sh parses (bash -n)"
else bad_ "0. deploy-stack.sh has a syntax error"; fi

# 1. help lists every flag, under its own group, and the env vars
bash "$SCRIPT" --help > "$S/help" 2>&1
missing=""
for f in --with-aks --no-aks --aks-cluster --aks-sample --aks-mode --aks-sensor-image --aks-sensor-tar --aks-pod-selector \
         CLOUDLENS_DEPLOY_AKS CLOUDLENS_AKS_CLUSTER CLOUDLENS_AKS_SAMPLE CLOUDLENS_AKS_MODE \
         CLOUDLENS_AKS_SENSOR_IMAGE CLOUDLENS_AKS_SENSOR_TAR CLOUDLENS_AKS_POD_SELECTOR \
         'Kubernetes (AKS)' '13b. AKS pod tapping'; do
  grep -q -- "$f" "$S/help" || missing="${missing} ${f}"
done
if [[ -z "$missing" ]]; then ok_ "1. --help lists every AKS flag, env var, the group and the phase"
else bad_ "1. --help is missing:${missing}"; fi

# 2. nothing AKS-related runs without --with-aks
run --with-kvo --no-vpb
if [[ "$(rc)" == "0" ]] && ! out_has 'Phase 13b' && ! out_has 'deploy-aks-tapping' && ! out_has 'kvo_k8s_config' && ! out_has 'AKS pod tapping'; then
  ok_ "2. without --with-aks the dry run never mentions Phase 13b, the engine or the KVO wiring"
else bad_ "2. AKS text appeared without --with-aks (rc=$(rc))"; fi

# 3. --aks-sample with KVO: the KVO wiring is printed BEFORE the engine call
run --with-kvo --no-vpb --aks-sample
k="$(out_line 'kvo_k8s_config.py')"; e="$(out_line 'bash scripts/deploy-aks-tapping.sh')"
if [[ "$(rc)" == "0" && -n "$k" && -n "$e" && "$k" -lt "$e" ]] && out_has 'Phase 13b: AKS pod tapping (daemonset)'; then
  ok_ "3. --aks-sample: Phase 13b runs, kvo_k8s_config.py (line $k) comes before deploy-aks-tapping.sh (line $e)"
else bad_ "3. expected the KVO wiring before the engine call (rc=$(rc), kvo=$k, engine=$e)"; fi

# 4. the KVO call: the presence is named after the sample cluster, the vController
#    is the Phase 13 name, the selector is the sample app's, no policy, key to a file
c="$(kvo_cmd)"
if [[ "$c" == *'--kvo 203.0.113.16 --name k8s-aks-rg-aks --vcontroller cloudlens-vcontroller --pod-selector '"'"'pod-name=^(web|loadgen)'"'"' --no-policy --key-out <tmpfile> --accept-eula --insecure'* ]]; then
  ok_ "4. kvo_k8s_config.py gets the KVO, k8s-<cluster>, the vController name, the sample selector, --no-policy and --key-out"
else bad_ "4. KVO wiring line wrong: $c"; fi

# 5. the engine call for the sample: the PRIVATE address, the shared VNet, the
#    vController's subnet, the sample app, the stack tags, --yes
c="$(engine_cmd)"
if [[ "$c" == *'--resource-group aks-rg --location westeurope --clms-ip 10.50.1.4 --project-key <key> --mode daemonset --stack-name aks-rg --custom-tags platform=aks,stack=aks-rg --yes --create-sample --vnet-name cloudlens-vnet --vnet-resource-group aks-rg --subnet-name vcontroller-subnet --sample-app'* ]] \
   && [[ "$c" != *'--cluster'* ]]; then
  ok_ "5. --aks-sample registers on the private address and lands in cloudlens-vnet/vcontroller-subnet with the sample app"
else bad_ "5. engine line wrong for the sample: $c"; fi

# 6. an existing cluster OUTSIDE the shared VNet registers on the public address
export STUB_AKS_SUBNET_ID="/subscriptions/0/resourceGroups/aks-rg/providers/Microsoft.Network/virtualNetworks/corp-vnet/subnets/nodes"
run --with-kvo --no-vpb --aks-cluster prod-aks
c="$(engine_cmd)"
if [[ "$(rc)" == "0" && "$c" == *'--clms-ip 203.0.113.11 '* && "$c" == *'--cluster prod-aks'* && "$c" != *'--create-sample'* ]] \
   && [[ "$(kvo_cmd)" == *'--name k8s-prod-aks --vcontroller cloudlens-vcontroller --no-policy'* ]]; then
  ok_ "6. --aks-cluster outside the VNet registers on the public address, names the presence k8s-prod-aks, taps every pod"
else bad_ "6. expected the public address for a cluster in corp-vnet (rc=$(rc)): $c"; fi

# 7. an existing cluster INSIDE the shared VNet registers on the private address
export STUB_AKS_SUBNET_ID="/subscriptions/0/resourceGroups/aks-rg/providers/Microsoft.Network/virtualNetworks/cloudlens-vnet/subnets/vcontroller-subnet"
run --with-kvo --no-vpb --aks-cluster prod-aks
c="$(engine_cmd)"
if [[ "$(rc)" == "0" && "$c" == *'--clms-ip 10.50.1.4 '* && "$c" == *'--cluster prod-aks'* ]]; then
  ok_ "7. --aks-cluster inside cloudlens-vnet registers on the private address"
else bad_ "7. expected the private address for a cluster in cloudlens-vnet: $c"; fi
unset STUB_AKS_SUBNET_ID

# 8. without KVO the wiring is skipped and the engine still runs on Phase 10's key
run --no-kvo --no-vpb --aks-sample
if [[ "$(rc)" == "0" ]] && ! out_has 'kvo_k8s_config' && [[ "$(engine_cmd)" == *'--project-key <key>'* ]] && out_has 'Phase 13b'; then
  ok_ "8. --no-kvo: no KVO wiring, the engine runs with the Phase 10 key"
else bad_ "8. expected the engine without the KVO wiring (rc=$(rc))"; fi

# 9. sidecar, an image, a tar and a pod selector all reach the right command
run --with-kvo --no-vpb --aks-cluster prod-aks --aks-mode SideCar --aks-sensor-image acr.io/cloudlens/sensor:6.13.0 \
    --aks-sensor-tar /tmp/CloudLens-Sensor-6.13.0.tar --aks-pod-selector '^(payments|checkout)'
c="$(engine_cmd)"
if [[ "$(rc)" == "0" ]] && out_has 'Phase 13b: AKS pod tapping (sidecar)' && [[ "$c" == *'--mode sidecar '* ]] \
   && [[ "$c" == *'--sensor-image acr.io/cloudlens/sensor:6.13.0'* && "$c" == *'--sensor-tar /tmp/CloudLens-Sensor-6.13.0.tar'* ]] \
   && [[ "$(kvo_cmd)" == *"--pod-selector 'pod-name=^(payments|checkout)'"* ]]; then
  ok_ "9. --aks-mode (any case), --aks-sensor-image, --aks-sensor-tar and --aks-pod-selector are passed through"
else bad_ "9. flags did not reach the commands (rc=$(rc)): $c"; fi

# 10. a bad mode stops the run before anything is deployed
run --with-kvo --no-vpb --aks-sample --aks-mode hostagent
if [[ "$(rc)" != "0" ]] && out_has 'daemonset or sidecar' && ! out_has 'Phase 6'; then
  ok_ "10. --aks-mode hostagent is refused up front, naming the two modes"
else bad_ "10. expected a refusal before Phase 6 (rc=$(rc))"; fi

# 11. the env-var route switches the step on; --no-aks on the command line wins over it
CLOUDLENS_DEPLOY_AKS=true CLOUDLENS_AKS_CLUSTER=env-aks CLOUDLENS_AKS_MODE=sidecar run --with-kvo --no-vpb
c="$(engine_cmd)"
env_ok=false
[[ "$(rc)" == "0" && "$c" == *'--mode sidecar '* && "$c" == *'--cluster env-aks'* ]] && env_ok=true
CLOUDLENS_DEPLOY_AKS=true CLOUDLENS_AKS_CLUSTER=env-aks run --with-kvo --no-vpb --no-aks
if [[ "$env_ok" == "true" && "$(rc)" == "0" ]] && ! out_has 'Phase 13b'; then
  ok_ "11. CLOUDLENS_DEPLOY_AKS / _AKS_CLUSTER / _AKS_MODE drive the step, and --no-aks overrides them"
else bad_ "11. env route or --no-aks override failed (env_ok=$env_ok, rc=$(rc))"; fi

# 12. the phase sits between 13 and 14, and the summary carries the one line
run --with-kvo --with-vpb --aks-sample
p13="$(out_line 'Phase 13: Adopt the vController')"; p13b="$(out_line 'Phase 13b: AKS pod tapping')"; p14="$(out_line 'Phase 14: Adopt the vPB')"
line='AKS pod tapping:    aks-rg-aks, daemonset, registers to 10.50.1.4'
if [[ "$(rc)" == "0" && -n "$p13" && -n "$p13b" && -n "$p14" && "$p13" -lt "$p13b" && "$p13b" -lt "$p14" ]] \
   && grep -q -- "$line" "$S/cwd/cloudlens-deploy-summary.txt" && out_has 'AKS pod tapping:     aks-rg-aks, daemonset, registers to 10.50.1.4'; then
  ok_ "12. Phase 13b runs after 13 and before 14; the summary file and the console carry the AKS line"
else bad_ "12. order or summary wrong (rc=$(rc), 13=$p13, 13b=$p13b, 14=$p14)"; fi

# 13. the DaemonSet manifest the engine substitutes is in place with its placeholders
M="$REPO/deploy/kubernetes/cloudlens-sensor-daemonset.yaml"
if [[ -f "$M" ]] && grep -q '__IMAGE_REPO__:__IMAGE_TAG__' "$M" && grep -q '__CLMS_IP__' "$M" && grep -q '__PROJECT_KEY__' "$M" \
   && grep -q 'runmode' "$M" && grep -q 'kubernetes_collector' "$M"; then
  ok_ "13. deploy/kubernetes/cloudlens-sensor-daemonset.yaml carries the four placeholders and the collector runmode"
else bad_ "13. the DaemonSet manifest is missing or lacks its placeholders"; fi

# 14. the engine's sidecar block renders --custom-tags as plain YAML strings.
#     The deploy always passes --custom-tags, and inside a heredoc bash 3.2
#     keeps the backslash of an escaped double quote, so this is the one line
#     of the engine the deploy's own flags can break; the sensor then received
#     a literal \"--custom_tags\" argument. Rendered under /bin/bash, the 3.2
#     build on macOS, with the function lifted straight out of the engine.
E="$REPO/scripts/deploy-aks-tapping.sh"
sb="$(awk '/^sidecar_block\(\) \{/,/^\}/' "$E")"
rendered="$(SENSOR_IMAGE=r/s:1 CLMS_IP=10.50.1.4 PROJECT_KEY=k CUSTOM_TAGS=platform=aks,stack=aks-rg \
            /bin/bash -c "$sb; sidecar_block" 2>&1)"
if [[ -n "$sb" && "$rendered" == *'"--custom_tags","platform=aks,stack=aks-rg"]'* && "$rendered" != *'\'* ]]; then
  ok_ "14. the engine's sidecar block carries --custom-tags as plain quoted YAML strings"
else bad_ "14. the sidecar block rendered wrongly: $rendered"; fi

echo
echo "$PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
