#!/usr/bin/env bash
# vpb - one-command entry point to the CloudLens vPB CLI (xf-client) on v3.15+
#
# Installed at /usr/local/bin/vpb during marketplace deploy or post-deploy
# bootstrap. Usage:
#
#   sudo vpb                  # drop into the CloudLensVPB# CLI
#   sudo vpb -c "show version"   # run a single command non-interactively
#
# Why: vPB v3.15 runs the CLI inside a K8s pod. There is no host-side SSH
# on port 2222 anymore. This wrapper hides the kubectl exec ceremony so
# operators and customers do not have to remember the full path.
set -euo pipefail

KUBECTL=/usr/bin/kubectl
KUBECONFIG_PATH=/etc/kubernetes/admin.conf
NAMESPACE=default
CONTAINER=vpbsystem
CLI=/usr/local/bin/xf-client

if [[ $EUID -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

POD=$($KUBECTL --kubeconfig="$KUBECONFIG_PATH" get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
        | awk '/vpbsystem/{print $1; exit}')

if [[ -z "$POD" ]]; then
  echo "vpb: no vpbsystem pod found in namespace $NAMESPACE." >&2
  echo "       Check that KCOS is fully up:" >&2
  echo "       $KUBECTL --kubeconfig=$KUBECONFIG_PATH get pods -A" >&2
  exit 1
fi

if [[ "${1:-}" == "-c" ]] && [[ -n "${2:-}" ]]; then
  # Non-interactive single-command mode
  exec $KUBECTL --kubeconfig="$KUBECONFIG_PATH" exec -i -n "$NAMESPACE" "$POD" \
       -c "$CONTAINER" -- bash -c "echo '$2' | $CLI"
fi

# Interactive mode (TTY)
exec $KUBECTL --kubeconfig="$KUBECONFIG_PATH" exec -it -n "$NAMESPACE" "$POD" \
     -c "$CONTAINER" -- "$CLI"
