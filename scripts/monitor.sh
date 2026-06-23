#!/usr/bin/env bash
# monitor.sh — Monitoreo continuo de infraestructura
set -euo pipefail

readonly RG="${RG:-rg-lab-autodeploy}"
readonly INTERVAL=300  # 5 minutos
readonly WEBHOOK="${TEAMS_WEBHOOK:-}"  # URL opcional de Teams

check_vm_state() {
  az vm get-instance-view \
    --resource-group "$RG" \
    --name "vm-lab-auto" \
    --query "instanceView.statuses[1].code" \
    --output tsv
}

notify() {
  local msg="$1"
  echo "[ALERT] $msg"
  if [[ -n "$WEBHOOK" ]]; then
    curl -s -X POST "$WEBHOOK" \
      -H "Content-Type: application/json" \
      -d "{\"text\":\"$msg\"}"
  fi
}

LAST_STATE=""
while true; do
  CURRENT_STATE=$(check_vm_state 2>/dev/null || echo "unknown")
  if [[ "$CURRENT_STATE" != "$LAST_STATE" ]]; then
    notify "VM state cambió: $LAST_STATE → $CURRENT_STATE"
    LAST_STATE="$CURRENT_STATE"
  fi
  sleep $INTERVAL
done
