#!/usr/bin/env bash
#
# Tap Kubernetes pod traffic in an AKS cluster with CloudLens sensors,
# end to end: cluster discovery or creation, access verification, sensor
# image supply, DaemonSet (or sidecar) deployment, a sample traffic app,
# and verification. Everything is resolved at run time from the flags and
# the live subscription; nothing about a customer is hardcoded.
#
# Why the shapes it has:
#   - DaemonSet is the automated path: one privileged pod per node taps
#     every pod on that node (Keysight vTAP UG 913-2798-01, "CloudLens
#     DaemonSet in Kubernetes"). One object, no customer pod restarts.
#   - Sidecar is per-pod: the sensor container is added INSIDE each
#     tapped pod's spec (vTAP UG, "Sidecar Deployment in Kubernetes").
#     Injecting containers into a customer's running Deployments restarts
#     their pods, so for customer apps this script renders a ready-to-
#     paste sidecar block and tells the operator exactly where it goes;
#     it only auto-injects into the SAMPLE app, which is ours to restart.
#   - kubectl, not helm: the DaemonSet manifest is Keysight's own chart
#     pre-rendered with helm template (deploy/kubernetes/
#     cloudlens-sensor-daemonset.yaml) and substituted here, so the deploy
#     needs the one tool every machine with cluster access already has.
#     Chart source: https://keysight-tech.github.io/cloudlens-helm/
#   - The sensor image must be in a registry the NODES can pull from
#     (vTAP UG: "you must upload the CloudLens Sensor image to the image
#     registry before you deploy the CloudLens DaemonSet"). On AKS that
#     is ACR, attached to the cluster so its kubelet identity holds
#     AcrPull; this script creates the registry and pushes a local sensor
#     tar when needed.
#   - Azure CNI on the stack's VNet subnet (--network-plugin azure): pods
#     get VNet addresses, so the sensors reach the vController on its
#     PRIVATE address over TCP 443 (vTAP UG, "Firewall Ports") with no
#     public exposure and no NAT in the way.
#
# Usage (standalone; deploy-stack.sh drives it with the same flags):
#   bash scripts/deploy-aks-tapping.sh \
#     --resource-group RG --location LOC --clms-ip IP --project-key KEY \
#     [--cluster NAME | --create-sample --vnet-name VNET \
#        --vnet-resource-group RG2 --subnet-name SUBNET] \
#     [--mode daemonset|sidecar] [--sensor-image <acr-uri:tag>] \
#     [--sensor-tar ~/Downloads/CloudLens-Sensor-6.13.0-359.tar] \
#     [--sample-app] [--stack-name NAME] [--custom-tags k=v,...] \
#     [--node-size Standard_D4s_v3] [--node-count 2] \
#     [--namespace cloudlens] [--yes]
#
# Exit codes: 0 done; 2 bad input; 3 no cluster access; 4 no sensor
# image; 5 cluster/nodepool creation failed; 6 deployment failed.
set -uo pipefail

RESOURCE_GROUP=""
LOCATION=""
CLUSTER=""
CREATE_SAMPLE=false
VNET_NAME=""
VNET_RG=""
SUBNET_NAME=""
CLMS_IP=""
PROJECT_KEY=""
MODE="daemonset"
SENSOR_IMAGE=""
SENSOR_TAR=""
SAMPLE_APP=false
STACK_NAME="cloudlens"
CUSTOM_TAGS=""
ASSUME_YES=false
NAMESPACE="cloudlens"
NODE_SIZE="Standard_D4s_v3"
NODE_COUNT=2

C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_RESET='\033[0m'
ok()   { echo -e "${C_GREEN}[ok]${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}[warn]${C_RESET} $1"; }
fail() { echo -e "${C_RED}[x]${C_RESET} $1" >&2; exit "${2:-2}"; }
step() { echo; echo -e "${C_BLUE}--- $1 ---${C_RESET}"; }
note() { echo "  -> $1"; }

# A flag that takes a value but was given none would make "shift 2" a no-op
# and spin the parser forever, so every valued flag is checked first.
val() { [[ $# -ge 2 && -n "$2" ]] || fail "$1 needs a value" 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)      val "$@"; RESOURCE_GROUP="$2"; shift 2 ;;
    --location)            val "$@"; LOCATION="$2"; shift 2 ;;
    --cluster)             val "$@"; CLUSTER="$2"; shift 2 ;;
    --create-sample)       CREATE_SAMPLE=true; shift ;;
    --vnet-name)           val "$@"; VNET_NAME="$2"; shift 2 ;;
    --vnet-resource-group) val "$@"; VNET_RG="$2"; shift 2 ;;
    --subnet-name)         val "$@"; SUBNET_NAME="$2"; shift 2 ;;
    --clms-ip)             val "$@"; CLMS_IP="$2"; shift 2 ;;
    --project-key)         val "$@"; PROJECT_KEY="$2"; shift 2 ;;
    --mode)                val "$@"; MODE="$(echo "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
    --sensor-image)        val "$@"; SENSOR_IMAGE="$2"; shift 2 ;;
    --sensor-tar)          val "$@"; SENSOR_TAR="$2"; shift 2 ;;
    --sample-app)          SAMPLE_APP=true; shift ;;
    --stack-name)          val "$@"; STACK_NAME="$2"; shift 2 ;;
    --custom-tags)         val "$@"; CUSTOM_TAGS="$2"; shift 2 ;;
    --namespace)           val "$@"; NAMESPACE="$2"; shift 2 ;;
    --node-size)           val "$@"; NODE_SIZE="$2"; shift 2 ;;
    --node-count)          val "$@"; NODE_COUNT="$2"; shift 2 ;;
    -y|--yes)              ASSUME_YES=true; shift ;;
    -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DS_TEMPLATE="$REPO_ROOT/deploy/kubernetes/cloudlens-sensor-daemonset.yaml"

# Everything that can be judged from the flags alone is judged here, before
# the first az call, so a typo costs a second and not a login prompt.
[[ -n "$RESOURCE_GROUP" ]] || fail "--resource-group is required (the group that holds, or will hold, the cluster)"
[[ -n "$LOCATION" ]]       || fail "--location is required (the Azure region, e.g. eastus2)"
[[ -n "$CLMS_IP" ]]        || fail "--clms-ip is required (the vController the sensors register to: its PRIVATE address when the cluster shares the VNet)"
[[ -n "$PROJECT_KEY" ]]    || fail "--project-key is required (vController project page shows it)"
case "$MODE" in daemonset|sidecar) ;; *) fail "--mode must be daemonset or sidecar" ;; esac
[[ "$NODE_COUNT" =~ ^[1-9][0-9]*$ ]] || fail "--node-count must be a whole number of nodes, 1 or more"
if [[ "$CREATE_SAMPLE" == "true" ]]; then
  [[ -n "$VNET_NAME" && -n "$SUBNET_NAME" ]] \
    || fail "--create-sample needs --vnet-name and --subnet-name (the stack's VNet and a subnet with room for the pods)"
fi
[[ -n "$VNET_RG" ]] || VNET_RG="$RESOURCE_GROUP"
[[ -f "$DS_TEMPLATE" ]] || fail "missing $DS_TEMPLATE (run from a repo checkout)"

command -v az >/dev/null 2>&1 || fail "Azure CLI not found (https://learn.microsoft.com/cli/azure/install-azure-cli)"

# kubectl: preinstalled in Azure Cloud Shell; anywhere else, say exactly
# what to do rather than silently curl a binary onto the machine.
if ! command -v kubectl >/dev/null 2>&1; then
  fail "kubectl is not installed. Azure Cloud Shell has it preinstalled; on this
machine run 'az aks install-cli' (or https://kubernetes.io/docs/tasks/tools/) and re-run." 2
fi

SUB_ID=$(az account show --query id -o tsv 2>/dev/null) \
  || fail "Azure auth missing/expired. Run: az login --use-device-code"

# =====================================================================
# 1. The cluster: an existing one (discovered or named) or a sample.
# =====================================================================
step "Cluster"
if [[ "$CREATE_SAMPLE" != "true" ]]; then
  az group show -n "$RESOURCE_GROUP" --query name -o tsv >/dev/null 2>&1 \
    || fail "Resource group ${RESOURCE_GROUP} does not exist in subscription ${SUB_ID}.
Check --resource-group, or add --create-sample to build the cluster (and the
group) from scratch." 2
fi
if [[ "$CREATE_SAMPLE" != "true" && -z "$CLUSTER" ]]; then
  clusters=$(az aks list -g "$RESOURCE_GROUP" --query '[].name' -o tsv 2>/dev/null)
  if [[ -z "$clusters" ]]; then
    fail "No AKS clusters in resource group ${RESOURCE_GROUP} and --create-sample was not given.
Re-run with --create-sample --vnet-name <vnet> --subnet-name <subnet> to build
a small test cluster (${NODE_COUNT}x ${NODE_SIZE}, about 10 minutes), or
--cluster <name> for a cluster in this group." 2
  fi
  if [[ $(echo "$clusters" | wc -l) -eq 1 ]]; then
    CLUSTER="$clusters"
    ok "One AKS cluster in ${RESOURCE_GROUP}: ${CLUSTER}"
  elif [[ "$ASSUME_YES" == "true" || ! -t 0 ]]; then
    fail "Multiple AKS clusters in ${RESOURCE_GROUP}; pass --cluster <name>:
$(echo "$clusters" | sed 's/^/  /')" 2
  else
    echo "  AKS clusters in ${RESOURCE_GROUP}:"
    i=0; rows=()
    while IFS= read -r c; do i=$((i+1)); rows+=("$c"); echo "    $i) $c"; done <<< "$clusters"
    read -rp "  Choose 1-$i: " pick || true
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= i )) || fail "not a listed cluster" 2
    CLUSTER="${rows[$((pick-1))]}"
  fi
fi
if [[ "$CREATE_SAMPLE" != "true" ]]; then
  # A named cluster is checked here so a typo reads as bad input, not as a
  # credentials failure three steps later.
  az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER" --query name -o tsv >/dev/null 2>&1 \
    || fail "AKS cluster ${CLUSTER} not found in resource group ${RESOURCE_GROUP}.
Check --cluster and --resource-group (az aks list -o table), or add
--create-sample to build one." 2
fi

# AKS gives Services their own virtual range (default 10.0.0.0/16) and
# refuses a cluster whose service range overlaps the VNet. The deploy's own
# VNet is 10.50.0.0/16, but a customer VNet at 10.0.0.0/16 is common, so the
# first candidate that overlaps nothing wins. Prints "<cidr> <dns-ip>".
pick_service_cidr() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" <<'PY'
import ipaddress, sys
vnet = [ipaddress.ip_network(p, strict=False) for p in sys.argv[1].split()]
for cand in ("10.0.0.0/16", "172.30.0.0/16", "10.254.0.0/16", "192.168.0.0/16"):
    net = ipaddress.ip_network(cand)
    if not any(net.overlaps(v) for v in vnet):
        print(cand, net.network_address + 10)
        break
PY
  else
    echo "10.0.0.0/16 10.0.0.10"
  fi
}

if [[ "$CREATE_SAMPLE" == "true" ]]; then
  CLUSTER="${CLUSTER:-${STACK_NAME}-aks}"
  step "Creating the sample AKS cluster '${CLUSTER}' (~10 minutes)"

  # The subnet is the whole point of --create-sample: Azure CNI puts every
  # pod on it, which is what lets the sensors reach the vController's
  # private address. Resolved to its id because that is what aks create takes.
  subnet_id=$(az network vnet subnet show -g "$VNET_RG" --vnet-name "$VNET_NAME" \
                -n "$SUBNET_NAME" --query id -o tsv 2>/dev/null)
  [[ -n "$subnet_id" ]] || fail "Subnet ${SUBNET_NAME} not found in VNet ${VNET_NAME} (resource group ${VNET_RG}).
Check --vnet-name, --vnet-resource-group and --subnet-name. The deploy's shared
network is cloudlens-vnet in the deploy's own resource group." 2
  subnet_prefix=$(az network vnet subnet show -g "$VNET_RG" --vnet-name "$VNET_NAME" \
                    -n "$SUBNET_NAME" --query addressPrefix -o tsv 2>/dev/null)
  note "Cluster subnet: ${VNET_NAME}/${SUBNET_NAME} (${subnet_prefix:-prefix unknown})"
  # Azure CNI reserves 30 pod addresses per node up front and keeps one
  # spare node for upgrades; a subnet too small for that fails at scale-out,
  # not at create, so the arithmetic is done here where it is visible.
  plen="${subnet_prefix##*/}"
  if [[ "$plen" =~ ^[0-9]+$ ]]; then
    usable=$(( (1 << (32 - plen)) - 5 ))
    needed=$(( (NODE_COUNT + 1) * 31 ))
    if (( usable < needed )); then
      warn "Subnet ${subnet_prefix} has ${usable} usable addresses; Azure CNI wants about ${needed}"
      warn "for ${NODE_COUNT} nodes (31 per node plus one spare node). Use a /24 or larger."
    fi
  fi

  vnet_prefixes=$(az network vnet show -g "$VNET_RG" -n "$VNET_NAME" \
                    --query 'addressSpace.addressPrefixes' -o tsv 2>/dev/null | tr '\n' ' ')
  svc_pick=$(pick_service_cidr "$vnet_prefixes")
  [[ -n "$svc_pick" ]] || fail "No service CIDR candidate avoids the VNet ranges (${vnet_prefixes}); pick one by hand with az aks create --service-cidr" 5
  SERVICE_CIDR="${svc_pick%% *}"
  DNS_IP="${svc_pick##* }"

  if ! az group show -n "$RESOURCE_GROUP" --query name -o tsv >/dev/null 2>&1; then
    az group create -n "$RESOURCE_GROUP" -l "$LOCATION" \
      --tags "cloudlens:stack=${STACK_NAME}" "deployedBy=cloudlens-stack" --output none \
      || fail "could not create resource group ${RESOURCE_GROUP}" 5
    ok "Created resource group ${RESOURCE_GROUP} in ${LOCATION}."
  fi

  # Tagged twice on purpose: cloudlens:stack=<stack> is the key every stack
  # resource carries, deployedBy=cloudlens-stack is the one teardown-stack.sh
  # already attributes ownership by.
  state=$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER" --query provisioningState -o tsv 2>/dev/null)
  case "$state" in
    "")
      note "Creating ${CLUSTER}: ${NODE_COUNT}x ${NODE_SIZE}, Azure CNI on ${SUBNET_NAME}, services on ${SERVICE_CIDR}"
      az aks create -g "$RESOURCE_GROUP" -n "$CLUSTER" --location "$LOCATION" \
        --network-plugin azure --vnet-subnet-id "$subnet_id" \
        --service-cidr "$SERVICE_CIDR" --dns-service-ip "$DNS_IP" \
        --node-count "$NODE_COUNT" --node-vm-size "$NODE_SIZE" \
        --generate-ssh-keys \
        --tags "cloudlens:stack=${STACK_NAME}" "deployedBy=cloudlens-stack" \
        --no-wait --output none \
        || fail "az aks create failed (vCPU quota in ${LOCATION}? the cluster identity
needs Network Contributor on the subnet, which the CLI grants only when you
can assign roles; see the error above)" 5 ;;
    Succeeded)
      ok "Cluster ${CLUSTER} already exists in ${RESOURCE_GROUP}; reusing it." ;;
    Failed|Canceled)
      fail "Cluster ${CLUSTER} exists in state ${state}. Delete it and re-run, or pass
--cluster <name> for a working one:
  az aks delete -g ${RESOURCE_GROUP} -n ${CLUSTER} --yes" 5 ;;
    *)
      note "Cluster ${CLUSTER} is ${state}; waiting for it." ;;
  esac
  note "Waiting for the control plane and the node pool (5-10 min is normal)..."
  az aks wait -g "$RESOURCE_GROUP" -n "$CLUSTER" --created --interval 30 --timeout 1800 \
    || fail "cluster never reached the Succeeded state (az aks show -g ${RESOURCE_GROUP} -n ${CLUSTER})" 5
  ok "Cluster ${CLUSTER} ready."
fi

# =====================================================================
# 2. kubectl access, verified before anything is applied.
# =====================================================================
step "Cluster access"
KCFG="$HOME/.kube/cloudlens-aks-${CLUSTER}"
mkdir -p "$HOME/.kube"
# A private kubeconfig: this deploy never rewrites the customer's default
# context. --admin fetches the cluster-admin certificate, which needs no
# kubelogin and works on every cluster that still allows local accounts.
cred_out=$(az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER" --admin \
             --file "$KCFG" --overwrite-existing 2>&1)
if [[ $? -ne 0 ]]; then
  case "$(printf '%s' "$cred_out" | tr '[:upper:]' '[:lower:]')" in
    *"local accounts"*|*"static credential"*|*"disablelocalaccounts"*|*"azure active directory"*|*"entra"*)
      # An operator who already followed the instructions below has a working
      # Entra kubeconfig at this path; keep it instead of failing twice.
      if [[ -f "$KCFG" ]] && kubectl --kubeconfig "$KCFG" get --raw=/version --request-timeout=20s >/dev/null 2>&1; then
        ok "Using the Entra ID kubeconfig already at ${KCFG}."
      else
        fail "${CLUSTER} is Entra ID only (local accounts disabled), so the admin
certificate is refused. Fetch user credentials, convert them to use the Azure
CLI token, then re-run this script with the same flags:
  az aks get-credentials -g ${RESOURCE_GROUP} -n ${CLUSTER} --file ${KCFG} --overwrite-existing
  kubelogin convert-kubeconfig -l azurecli --kubeconfig ${KCFG}
(kubelogin: 'az aks install-cli', or https://azure.github.io/kubelogin/.) Your
identity needs the Azure Kubernetes Service RBAC Cluster Admin role on the
cluster, or a cluster role that can create DaemonSets." 3
      fi ;;
    *) fail "az aks get-credentials failed for ${CLUSTER}:
${cred_out}" 3 ;;
  esac
fi
chmod 600 "$KCFG" 2>/dev/null || true
K=(kubectl --kubeconfig "$KCFG")

probe_out=$("${K[@]}" get --raw=/version --request-timeout=20s 2>&1)
if [[ $? -ne 0 ]]; then
  case "$probe_out" in
    *Unauthorized*|*"must be logged in"*|*orbidden*)
      fail "Credentials for ${CLUSTER} were fetched but the API server rejects them.
On an Entra ID cluster the kubeconfig needs kubelogin and your identity needs
the Azure Kubernetes Service RBAC Cluster Admin role:
  az role assignment create --role \"Azure Kubernetes Service RBAC Cluster Admin\" \\
      --assignee <your-upn-or-object-id> \\
      --scope \$(az aks show -g ${RESOURCE_GROUP} -n ${CLUSTER} --query id -o tsv)" 3 ;;
    *)
      fail "Cannot reach the ${CLUSTER} API server: ${probe_out}
If it is a private cluster, run this from inside that VNet (a jump VM, or
Cloud Shell attached to the VNet), or let AKS run kubectl for you:
  az aks command invoke -g ${RESOURCE_GROUP} -n ${CLUSTER} --command 'kubectl get nodes'" 3 ;;
  esac
fi
if ! "${K[@]}" auth can-i create daemonsets -A >/dev/null 2>&1; then
  fail "Authenticated to ${CLUSTER} but not allowed to create DaemonSets.
Ask the cluster admin for a role that can manage workloads cluster-wide." 3
fi
nodes=$("${K[@]}" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
ok "Authenticated to ${CLUSTER}: ${nodes} node(s), DaemonSet rights confirmed."

# =====================================================================
# 3. The sensor image, in a registry the NODES can pull from.
# =====================================================================
step "Sensor image"
ACR_NAME=""; ACR_LOGIN=""
if [[ -z "$SENSOR_IMAGE" ]]; then
  # One registry per resource group. A re-run finds it by prefix, so the
  # name never depends on recomputing the same hash; the hash only makes a
  # NEW name globally unique, which ACR demands.
  ACR_NAME=$(az acr list -g "$RESOURCE_GROUP" \
               --query "[?starts_with(name,'cloudlens')].name | [0]" -o tsv 2>/dev/null)
  if [[ -z "$ACR_NAME" || "$ACR_NAME" == "None" ]]; then
    hash=$(printf '%s' "${SUB_ID}/${RESOURCE_GROUP}" | shasum 2>/dev/null | cut -c1-8)
    [[ -n "$hash" ]] || hash=$(printf '%s' "${SUB_ID}/${RESOURCE_GROUP}" | cksum | cut -d' ' -f1)
    ACR_NAME="cloudlens${hash}"
  fi
  tag=""
  if az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" --query name -o tsv >/dev/null 2>&1; then
    ACR_LOGIN=$(az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" --query loginServer -o tsv)
    tag=$(az acr repository show-tags -n "$ACR_NAME" --repository cloudlens-sensor -o tsv 2>/dev/null \
            | sort -V | tail -1)
  fi
  if [[ -n "$tag" ]]; then
    SENSOR_IMAGE="${ACR_LOGIN}/cloudlens-sensor:${tag}"
    ok "Using the sensor image already in ACR: ${SENSOR_IMAGE}"
  else
    # No image in ACR: push a local sensor tar (the download every CloudLens
    # entitlement includes). Auto-found so a customer who saved it anywhere
    # obvious does nothing extra.
    if [[ -z "$SENSOR_TAR" ]]; then
      SENSOR_TAR=$(ls -t "$HOME"/Downloads/CloudLens-Sensor-*.tar ./CloudLens-Sensor-*.tar 2>/dev/null | head -1)
    fi
    if [[ -z "$SENSOR_TAR" || ! -f "$SENSOR_TAR" ]]; then
      fail "No sensor image available. One of:
  --sensor-image <uri:tag>     an image already in a registry the nodes reach
  --sensor-tar <path>          the CloudLens-Sensor-<ver>.tar from Keysight
                               (support.ixiacom.com downloads; ~900MB)
The tar is loaded and pushed to ACR ${ACR_LOGIN:-${ACR_NAME}.azurecr.io} automatically." 4
    fi
    # Azure Cloud Shell has no Docker daemon, so unlike the AWS path this
    # push has to run from a workstation; say so instead of failing inside
    # docker load.
    command -v docker >/dev/null 2>&1 \
      || fail "docker is needed to push ${SENSOR_TAR} to ACR. Azure Cloud Shell has no
Docker daemon: run this step from a machine with Docker, or push the image to
any registry the nodes can reach and pass --sensor-image <uri:tag>." 4
    docker info >/dev/null 2>&1 || fail "docker is installed but its daemon is not running" 4
    ver=$(basename "$SENSOR_TAR" | sed -E 's/CloudLens-Sensor-(.+)\.tar/\1/')
    if [[ -z "$ACR_LOGIN" ]]; then
      note "Creating registry ${ACR_NAME} (Basic) in ${RESOURCE_GROUP} ..."
      az acr create -g "$RESOURCE_GROUP" -n "$ACR_NAME" --sku Basic --location "$LOCATION" \
        --tags "cloudlens:stack=${STACK_NAME}" "deployedBy=cloudlens-stack" --output none \
        || fail "az acr create failed for ${ACR_NAME} (the name must be globally unique and
5-50 lowercase alphanumerics; see the error above)" 4
      ACR_LOGIN=$(az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" --query loginServer -o tsv)
    fi
    note "Pushing ${SENSOR_TAR} (version ${ver}) to ${ACR_LOGIN} ..."
    az acr login -n "$ACR_NAME" >/dev/null 2>&1 \
      || fail "az acr login to ${ACR_NAME} failed (you need AcrPush on the registry)" 4
    loaded=$(docker load -i "$SENSOR_TAR" 2>/dev/null | sed -n 's/^Loaded image: //p' | head -1)
    [[ -n "$loaded" ]] || fail "docker load produced no image from ${SENSOR_TAR}" 4
    docker tag "$loaded" "${ACR_LOGIN}/cloudlens-sensor:${ver}" || fail "docker tag failed" 4
    docker push "${ACR_LOGIN}/cloudlens-sensor:${ver}" >/dev/null || fail "docker push failed" 4
    SENSOR_IMAGE="${ACR_LOGIN}/cloudlens-sensor:${ver}"
    ok "Sensor image pushed: ${SENSOR_IMAGE}"
  fi
else
  ok "Using the supplied sensor image: ${SENSOR_IMAGE}"
fi
IMAGE_REPO="${SENSOR_IMAGE%:*}"
IMAGE_TAG="${SENSOR_IMAGE##*:}"

# AKS nodes pull from an ACR only once the cluster's kubelet identity holds
# AcrPull on it, which --attach-acr grants. The grant is checked first
# because the update that makes it is a minutes-long operation on every run.
attach_acr() {
  local acr="$1" acr_id="" kubelet_oid="" existing=""
  acr_id=$(az acr show -n "$acr" --query id -o tsv 2>/dev/null)
  kubelet_oid=$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER" \
                  --query identityProfile.kubeletidentity.objectId -o tsv 2>/dev/null)
  if [[ -n "$acr_id" && -n "$kubelet_oid" ]]; then
    existing=$(az role assignment list --assignee "$kubelet_oid" --scope "$acr_id" \
                 --role AcrPull --query '[0].id' -o tsv 2>/dev/null)
    [[ -n "$existing" ]] && return 0
  fi
  az aks update -g "$RESOURCE_GROUP" -n "$CLUSTER" --attach-acr "$acr" --output none
}
image_host="${IMAGE_REPO%%/*}"
case "$image_host" in
  *.azurecr.io)
    acr_short="${image_host%%.*}"
    if attach_acr "$acr_short"; then
      ok "Cluster ${CLUSTER} can pull from ${image_host} (AcrPull on its kubelet identity)."
    elif [[ -n "$ACR_NAME" ]]; then
      fail "Could not attach ${image_host} to ${CLUSTER}. Granting AcrPull needs Owner or
User Access Administrator on the registry. Have it granted, then re-run, or:
  az aks update -g ${RESOURCE_GROUP} -n ${CLUSTER} --attach-acr ${acr_short}" 4
    else
      warn "Could not attach ${image_host} to ${CLUSTER}. If the sensor pods stay in"
      warn "ImagePullBackOff: az aks update -g ${RESOURCE_GROUP} -n ${CLUSTER} --attach-acr ${acr_short}"
    fi ;;
  *)
    note "Registry ${image_host} is not an ACR; the nodes must already be able to pull from it." ;;
esac

# =====================================================================
# 4. Deploy: DaemonSet (automated) or sidecar (sample auto, customer guided)
# =====================================================================
"${K[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1 || "${K[@]}" create namespace "$NAMESPACE" >/dev/null

sidecar_block() {
  # The documented sidecar container (vTAP UG "Sidecar Deployment"), with
  # this run's real values. Indented for a containers: list. The custom
  # tags pair is built before the heredoc, not inside it: within a heredoc
  # bash 3.2 keeps the backslash in front of an escaped double quote, so an
  # escaped pair inside a ${CUSTOM_TAGS:+...} expansion reached the YAML as
  # \"--custom_tags\", which the sensor received as a literal argument.
  local tags_pair=""
  if [[ -n "$CUSTOM_TAGS" ]]; then
    tags_pair=",
                 \"--custom_tags\",\"${CUSTOM_TAGS}\""
  fi
  cat <<SIDE
        - name: cloudlens-sensor
          image: ${SENSOR_IMAGE}
          args: ["--auto_update","n","--accept_eula","yes","--ssl_verify","no",
                 "--server","${CLMS_IP}","--project_key","${PROJECT_KEY}"${tags_pair}]
          securityContext:
            allowPrivilegeEscalation: true
            capabilities:
              add: ["SYS_MODULE","SYS_RESOURCE","NET_RAW","NET_ADMIN"]
          volumeMounts:
          - {name: host-root, mountPath: /host}
          - {name: host-log, mountPath: /var/log/cloudlens}
          - {name: lib-modules, mountPath: /lib/modules}
SIDE
}
sidecar_volumes() {
  cat <<VOLS
      - {name: host-root, hostPath: {path: /}}
      - {name: host-log, hostPath: {path: /var/log}}
      - {name: lib-modules, hostPath: {path: /lib/modules}}
VOLS
}

if [[ "$MODE" == "daemonset" ]]; then
  step "Deploying the CloudLens sensor DaemonSet"
  # The chart renders its ClusterRoleBinding subject in namespace cloudlens;
  # with --namespace elsewhere the ServiceAccount would land in one namespace
  # and the binding point at another, so the subject follows the namespace.
  sed -e "s|__IMAGE_REPO__|${IMAGE_REPO}|g" \
      -e "s|__IMAGE_TAG__|${IMAGE_TAG}|g" \
      -e "s|__CLMS_IP__|${CLMS_IP}|g" \
      -e "s|__PROJECT_KEY__|${PROJECT_KEY}|g" \
      -e "s|^  namespace: cloudlens\$|  namespace: ${NAMESPACE}|" \
      "$DS_TEMPLATE" | "${K[@]}" -n "$NAMESPACE" apply -f - \
    || fail "kubectl apply of the DaemonSet failed" 6
  note "Waiting for the sensor pods (image pull is ~1GB per node on first run)..."
  if ! "${K[@]}" -n "$NAMESPACE" rollout status ds/cloudlens-sensor --timeout=420s; then
    "${K[@]}" -n "$NAMESPACE" get pods -o wide || true
    fail "The sensor DaemonSet did not become ready. Common causes: the nodes
cannot pull ${SENSOR_IMAGE} (the kubelet identity needs AcrPull on the
registry: az aks update -g ${RESOURCE_GROUP} -n ${CLUSTER} --attach-acr <acr>),
or a PodSecurity policy blocks privileged pods in namespace ${NAMESPACE}." 6
  fi
  ready=$("${K[@]}" -n "$NAMESPACE" get ds cloudlens-sensor -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}')
  ok "Sensor DaemonSet ready on ${ready} node(s)."
else
  step "Sidecar mode"
  mkdir -p "${REPO_ROOT}/inventory"
  snippet="${REPO_ROOT}/inventory/generated.aks-sidecar-${CLUSTER}.yaml"
  { echo "# CloudLens sidecar for cluster ${CLUSTER}, generated $(date -u +%FT%TZ)"
    echo "# 1. Add this container to each Deployment you want tapped, under"
    echo "#    spec.template.spec.containers:"
    sidecar_block
    echo "# 2. And these volumes under spec.template.spec.volumes:"
    sidecar_volumes
    echo "# 3. kubectl apply the changed Deployment; its pods restart with the"
    echo "#    sensor inside and register to ${CLMS_IP} within a minute."
  } > "$snippet"
  ok "Sidecar block written to ${snippet} with this run's live values."
  note "Customer pods are NEVER modified automatically: adding a sidecar"
  note "restarts them, and that call belongs to whoever owns the app."
fi

# =====================================================================
# 5. Sample traffic app (with the sidecar inlined when that mode is on)
# =====================================================================
if [[ "$SAMPLE_APP" == "true" ]]; then
  step "Sample traffic app (web x2 + loadgen, namespace cloudlens-demo)"
  extra_containers=""; extra_volumes=""
  if [[ "$MODE" == "sidecar" ]]; then
    extra_containers="$(sidecar_block)"
    extra_volumes="$(sidecar_volumes)"
  fi
  # Docker Hub official images, spelled out with their registry: three
  # anonymous pulls sit far under the Hub rate limit, and no Azure-side
  # registry carries both nginx and busybox under stable public names.
  "${K[@]}" apply -f - <<APP || fail "sample app apply failed" 6
apiVersion: v1
kind: Namespace
metadata:
  name: cloudlens-demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: cloudlens-demo
spec:
  replicas: 2
  selector: {matchLabels: {app: web}}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
        - name: nginx
          image: docker.io/library/nginx:stable
          ports: [{containerPort: 80}]
${extra_containers}
      volumes:
${extra_volumes:-        []}
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: cloudlens-demo
spec:
  selector: {app: web}
  ports: [{port: 80}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loadgen
  namespace: cloudlens-demo
spec:
  replicas: 1
  selector: {matchLabels: {app: loadgen}}
  template:
    metadata:
      labels: {app: loadgen}
    spec:
      containers:
        - name: loadgen
          image: docker.io/library/busybox:stable
          command: ["/bin/sh","-c","while true; do wget -q -O /dev/null http://web.cloudlens-demo.svc.cluster.local/; sleep 1; done"]
APP
  "${K[@]}" -n cloudlens-demo rollout status deploy/web --timeout=180s || warn "web pods slow to start"
  "${K[@]}" -n cloudlens-demo rollout status deploy/loadgen --timeout=180s || warn "loadgen slow to start"
  ok "Sample app running: loadgen fetches web every second (continuous pod-to-pod HTTP)."
fi

# =====================================================================
# 6. What was built, and how to verify it end to end.
# =====================================================================
if [[ "$MODE" == "daemonset" ]]; then
  step "Verifying registration"
  # Two signs the sensors reached the vController, both checked from INSIDE
  # the cluster because that is where the sensors sit: a TCP open to 443 on
  # --clms-ip (vTAP UG "Firewall Ports": sensors need TCP 443 to the
  # Manager), and the sensor logs naming that address. Neither is fatal; the
  # ready DaemonSet above is the hard gate, these say where to look next.
  if "${K[@]}" -n "$NAMESPACE" run cloudlens-probe --image=docker.io/library/busybox:stable \
       --restart=Never --rm -i --quiet --pod-running-timeout=90s \
       --command -- nc -z -w 5 "$CLMS_IP" 443 >/dev/null 2>&1; then
    ok "TCP 443 to ${CLMS_IP} opens from a pod."
  else
    warn "A pod could not open TCP 443 to ${CLMS_IP}. Check the NSG on the vController"
    warn "allows 443 from the cluster subnet, and that --clms-ip is the address the pods"
    warn "route to (the PRIVATE one when the cluster shares the VNet)."
  fi
  sensor_pods=$("${K[@]}" -n "$NAMESPACE" get pods -l app.kubernetes.io/name=cloudlens-sensor \
                  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  total=0; for _p in $sensor_pods; do total=$((total+1)); done
  seen=0; attempt=0
  while (( attempt < 6 )); do
    seen=0
    for _p in $sensor_pods; do
      if "${K[@]}" -n "$NAMESPACE" logs "$_p" --tail=300 2>/dev/null | grep -q "$CLMS_IP"; then
        seen=$((seen+1))
      fi
    done
    (( seen == total && total > 0 )) && break
    attempt=$((attempt+1)); sleep 10
  done
  if (( total > 0 && seen == total )); then
    ok "All ${total} sensor pod(s) name ${CLMS_IP} in their logs (registering with project key ${PROJECT_KEY:0:8}...)."
  else
    note "${seen}/${total} sensor pod(s) mention ${CLMS_IP} in their logs so far; registration"
    note "shows in the vController UI within about a minute. To watch it:"
    note "  kubectl --kubeconfig ${KCFG} -n ${NAMESPACE} logs ds/cloudlens-sensor -f"
  fi
fi

step "AKS tapping deployed"
echo "  Cluster:        ${CLUSTER} (${nodes} nodes, resource group ${RESOURCE_GROUP})"
echo "  Mode:           ${MODE}"
echo "  Sensor image:   ${SENSOR_IMAGE}"
echo "  Registers to:   ${CLMS_IP} (project key ${PROJECT_KEY:0:8}...)"
echo "  Kubeconfig:     ${KCFG}"
echo
echo "  Verify, in order:"
echo "    kubectl --kubeconfig ${KCFG} -n ${NAMESPACE} get pods -o wide"
echo "    Then the vController UI (https://<clms>/cloudlens/login): the K8s"
echo "    sensors appear in the project within about a minute, one per"
[[ "$MODE" == "daemonset" ]] \
  && echo "    NODE, each publishing that node's pod labels for tap groups." \
  || echo "    tapped POD (sidecars register per pod)."
echo "    Pod labels become selectable in tap groups; tapped traffic follows"
echo "    the SAME tool path the VM sensors use (the vPB, when deployed)."
exit 0
