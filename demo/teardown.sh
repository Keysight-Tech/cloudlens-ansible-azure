#!/usr/bin/env bash
# =====================================================================
# NetRefer demo full teardown
# =====================================================================
# Nukes everything created by setup-netrefer-demo.sh. The KVO that was
# deployed earlier (kvo-test-rg) is left untouched - pass --include-kvo
# to also tear that down.
# =====================================================================
set -euo pipefail

INCLUDE_KVO=false
QUIET=false
for arg in "$@"; do
  case "$arg" in
    --include-kvo) INCLUDE_KVO=true ;;
    --quiet)       QUIET=true ;;
    -h|--help)
      sed -n '/^# Nukes/,/^# =====/p' "$0" | sed 's/^# //; /^=====/d'
      exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 1 ;;
  esac
done

RGS=("demo-prod-rg" "demo-cloudlens-rg" "demo-vectra-rg")
$INCLUDE_KVO && RGS+=("kvo-test-rg")

if [[ "$QUIET" != "true" ]]; then
  echo "About to delete (with --no-wait):"
  for rg in "${RGS[@]}"; do echo "  - $rg"; done
  read -rp "Proceed? [y/N] " yn
  [[ "${yn,,}" == "y" || "${yn,,}" == "yes" ]] || { echo "Cancelled."; exit 0; }
fi

for rg in "${RGS[@]}"; do
  if az group show -n "$rg" >/dev/null 2>&1; then
    az group delete -n "$rg" --yes --no-wait
    echo "✓ deletion initiated: $rg"
  else
    echo "  absent: $rg"
  fi
done

echo ""
echo "Deletion proceeds asynchronously in Azure (~30-60s)."
echo "Verify with: az group list --query \"[?starts_with(name,'demo-')||name=='kvo-test-rg'].name\" -o tsv"
