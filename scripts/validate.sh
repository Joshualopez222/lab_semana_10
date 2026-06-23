#!/usr/bin/env bash
# validate.sh — Verifica que todos los recursos fueron creados correctamente
set -euo pipefail

readonly RG="${RG:-rg-lab-autodeploy}"
readonly SUFFIX="${SUFFIX:-lab01}"
PASS=0; FAIL=0

check() {
  local name="$1"; shift
  if "$@" &>/dev/null; then
    echo "✅ $name"
    PASS=$((PASS + 1))
  else
    echo "❌ $name"
    FAIL=$((FAIL + 1))
  fi
}

# Verificar cada recurso
check "Resource Group"    az group show -n "$RG"
check "VNet"              az network vnet show -g "$RG" -n "vnet-lab"
check "Subnet snet-web"   az network vnet subnet show \
  -g "$RG" --vnet-name "vnet-lab" -n "snet-web"
check "NSG nsg-web"       az network nsg show -g "$RG" -n "nsg-web"
check "VM running" \
  bash -c "az vm get-instance-view -g \"$RG\" -n \"vm-lab-auto\" \
    --query \"instanceView.statuses[1].code\" -o tsv | grep -q \"running\""
check "Storage Account"   az storage account show -n "stlabautodeploy${SUFFIX}"

echo ""
echo "Resultados: $PASS OK / $FAIL FALLIDO"
[[ "$FAIL" -eq 0 ]] || exit 1
