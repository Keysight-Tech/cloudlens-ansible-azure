#!/usr/bin/env bash
# Docker entrypoint: routes a mode to the right action.
#
# Its other job is to fail loudly. The image used to print "Deploying to 0 VMs"
# and exit 0 when the Azure login failed or no VM matched, so a CI job went
# green having deployed nothing. Every path that would deploy to nothing now
# stops with a non-zero exit and says why.
set -euo pipefail
cd /work

TARGET_GROUPS="ubuntu_prod_vms redhat_prod_vms windows_prod_vms"
MOUNT_HINT='-v "$(pwd)/customer_input.yaml:/work/customer_input.yaml:ro"'

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }

# customer_input.yaml value by dotted path, empty when absent.
ci_get() {
  python3 - "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open("customer_input.yaml")) or {}
for k in sys.argv[1].split("."):
    d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)
PY
}

require_customer_input() {
  if [[ -d customer_input.yaml ]]; then
    die "customer_input.yaml is a directory, not your file. Docker creates an empty folder when the file you mount does not exist. Delete that folder, cd to the folder that holds customer_input.yaml, and mount it with $MOUNT_HINT"
  fi
  [[ -f customer_input.yaml ]] || die "Mount customer_input.yaml: $MOUNT_HINT"
}

# SSH from inside the container must not read the host's ~/.ssh/config when a
# whole ~/.ssh is mounted: macOS-only options (UseKeychain) abort a Linux ssh,
# and on a Linux host the file keeps the host uid, which ssh refuses as root
# ("Bad owner or permissions"). Either way every Linux VM went UNREACHABLE.
# ssh_args from ansible.cfg are kept; only the config file is dropped.
setup_ssh() {
  [[ -n "${ANSIBLE_SSH_ARGS:-}" ]] && return 0
  local base
  base="$(python3 -c "import configparser; c = configparser.ConfigParser(interpolation=None); c.read('ansible.cfg'); print(c.get('ssh_connection', 'ssh_args', fallback='-C -o ControlMaster=auto -o ControlPersist=60s'))")"
  export ANSIBLE_SSH_ARGS="-F /dev/null $base"
  if [[ -f "$HOME/.ssh/config" ]]; then
    note "Ignoring the mounted ~/.ssh/config inside the container; keys are used as configured in customer_input.yaml"
  fi
}

# Keep a log on the host when the customer mounts a folder for it.
setup_logs() {
  if [[ -d /work/logs && -w /work/logs ]]; then
    export ANSIBLE_LOG_PATH="${ANSIBLE_LOG_PATH:-/work/logs/ansible.log}"
  elif [[ ! -w /work ]]; then
    export ANSIBLE_LOG_PATH="${ANSIBLE_LOG_PATH:-/tmp/ansible.log}"
  fi
}

# Two logins are needed. The azure_rm inventory reads the AZURE_* variables
# itself, but the Windows WinRM bootstrap runs `az vm run-command`, and the az
# CLI does not read them. Without this every Windows VM failed in Docker.
azure_login() {
  if [[ -n "${AZURE_CLIENT_ID:-}" && -n "${AZURE_SECRET:-}" && -n "${AZURE_TENANT:-}" && -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
    local err
    err="$(mktemp)"
    # The secret goes in on stdin (az reads "-p @-" from it) through the printf
    # builtin, so it never appears in a process list: a Linux host's ps shows
    # the arguments of every process in every container.
    if ! printf '%s' "$AZURE_SECRET" | az login --service-principal \
          -u "$AZURE_CLIENT_ID" -p @- --tenant "$AZURE_TENANT" --output none 2>"$err"; then
      sed -n '1,3p' "$err" >&2
      rm -f "$err"
      die "Azure login with the service principal failed. Check AZURE_TENANT, AZURE_CLIENT_ID and AZURE_SECRET."
    fi
    rm -f "$err"
    az account set --subscription "$AZURE_SUBSCRIPTION_ID" \
      || die "The service principal cannot use subscription $AZURE_SUBSCRIPTION_ID."
  elif az account show >/dev/null 2>&1; then
    # An az login mounted from the host (-v $HOME/.azure:/root/.azure).
    if [[ -z "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
      AZURE_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
      export AZURE_SUBSCRIPTION_ID
    fi
  else
    die "Set Azure credentials: -e AZURE_SUBSCRIPTION_ID -e AZURE_TENANT -e AZURE_CLIENT_ID -e AZURE_SECRET (scripts/setup_azure_sp.sh creates a service principal)."
  fi
}

# Sets INVENTORY: the shipped azure_rm inventory, narrowed by
# customer_input.yaml azure.tag_filters / resource_groups / locations.
render_inventory() {
  INVENTORY="$(python3 scripts/render_azure_inventory.py customer_input.yaml /tmp/cloudlens-inventory)" \
    || die "customer_input.yaml could not be turned into an inventory (see above)."
  export INVENTORY
}

# Sets VM_COUNT to the VMs the deploy targets. An inventory that fails to
# parse is an error (ANSIBLE_INVENTORY_UNPARSED_FAILED is set in the image),
# and so is finding no VM at all.
count_vms() {
  local out err
  out="$(mktemp)"; err="$(mktemp)"
  if ! ansible-inventory -i "$INVENTORY" --list >"$out" 2>"$err"; then
    grep -v '^\s*$' "$err" | tail -8 >&2
    rm -f "$out" "$err"
    die "Azure VM discovery failed. Check the credentials and that the service principal can read the subscription."
  fi
  rm -f "$err"
  local summary
  summary="$(python3 - "$out" $TARGET_GROUPS <<'PY'
import json, sys
inv = json.load(open(sys.argv[1]))
groups = sys.argv[2:]
hosts = set()
parts = []
for g in groups:
    members = inv.get(g, {}).get("hosts", [])
    hosts.update(members)
    parts.append("%s=%d" % (g, len(members)))
print(len(hosts), " ".join(parts))
PY
)"
  rm -f "$out"
  VM_COUNT="${summary%% *}"
  note "Discovered $VM_COUNT VMs (${summary#* })"
  if [[ "$VM_COUNT" == "0" ]]; then
    die "No VM matched. Tag each VM cloudlens=yes os=ubuntu|rhel|windows env=prod, or set azure.tag_filters in customer_input.yaml to the tags you use."
  fi
}

# ANSIBLE_FORKS wins, then deploy.forks from customer_input.yaml, then a size
# based default. A --forks flag outranks ANSIBLE_FORKS inside Ansible, so the
# override has to be applied here or it silently does nothing.
pick_forks() {
  local f="${ANSIBLE_FORKS:-}"
  if [[ -z "$f" ]]; then
    f="$(ci_get deploy.forks)"
    [[ "$f" =~ ^[0-9]+$ && "$f" -gt 0 ]] || f=""
  fi
  if [[ -z "$f" ]]; then
    if   (( VM_COUNT <= 50 ));   then f=20
    elif (( VM_COUNT <= 500 ));  then f=50
    elif (( VM_COUNT <= 2000 )); then f=200
    else                              f=500
    fi
  fi
  FORKS="$f"
}

setup_ssh
setup_logs

mode="${1:-deploy}"
case "$mode" in
  deploy)
    require_customer_input
    azure_login
    render_inventory
    count_vms
    pick_forks
    if (( VM_COUNT > 2000 )); then
      shard_size="$(ci_get deploy.shard_size)"
      [[ "$shard_size" =~ ^[0-9]+$ && "$shard_size" -gt 0 ]] || shard_size=500
      note "More than 2000 VMs: deploying in shards of $shard_size with $FORKS forks each"
      SHARD_SIZE="${SHARD_SIZE:-$shard_size}" exec bash deploy/shard.sh "$VM_COUNT" "$FORKS"
    fi
    note "Deploying to $VM_COUNT VMs with $FORKS forks"
    exec ansible-playbook -i "$INVENTORY" deploy.yaml -e "@customer_input.yaml" --forks "$FORKS"
    ;;

  cleanup)
    require_customer_input
    azure_login
    render_inventory
    count_vms
    pick_forks
    exec ansible-playbook -i "$INVENTORY" cleanup.yaml -e "@customer_input.yaml" --forks "$FORKS"
    ;;

  inventory)
    if [[ -f customer_input.yaml ]]; then
      render_inventory
    else
      INVENTORY=inventory/azure_rm.yaml
    fi
    exec ansible-inventory -i "$INVENTORY" --graph
    ;;

  shard)
    shift
    require_customer_input
    azure_login
    render_inventory
    exec bash deploy/shard.sh "$@"
    ;;

  shell)
    shift
    exec bash "$@"
    ;;

  *)
    exec "$@"
    ;;
esac
