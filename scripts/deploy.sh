#!/usr/bin/env bash
# ============================================================
# deploy.sh — Despliegue completo de infraestructura Azure
# Uso: ./deploy.sh [--dry-run] [--destroy]
# Exit codes: 0=éxito, 1=error, 2=args inválidos, 127=dep faltante
# ============================================================
set -euo pipefail
IFS=$'\n\t'

# ── Directorio del script (portable) ────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
LOG_FILE="${SCRIPT_DIR}/../deploy-$(date +%Y%m%d-%H%M%S).log"
readonly LOG_FILE

# ── Variables configurables ──────────────────────────────────
readonly LOCATION="${LOCATION:-eastus2}"
readonly SUFFIX="${SUFFIX:-lab01}"
readonly RG="${RG:-rg-lab-autodeploy}"
readonly VNET_NAME="vnet-lab"
readonly SUBNET_NAME="snet-web"
readonly VM_NAME="vm-lab-auto"
readonly NSG_NAME="nsg-web"
readonly ST_NAME="stlabautodeploy${SUFFIX}"
readonly KV_NAME="kv-lab-auto-${SUFFIX}"

# ── Flags ────────────────────────────────────────────────────
DRY_RUN=false
DESTROY=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true ;;
    --destroy) DESTROY=true ;;
    *) echo "Arg desconocido: $1"; exit 2 ;;
  esac
  shift
done

# ── Logging estructurado (JSON a log file y stdout) ──────────
log_json() {
  local level="$1"; shift
  local msg="$*"
  local entry
  entry=$(printf '{"time":"%s","level":"%s","msg":"%s","script":"%s"}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$msg" "deploy.sh")
  echo "$entry" | tee -a "$LOG_FILE"
}
log()  { log_json "INFO"  "$@"; }
warn() { log_json "WARN"  "$@"; }
err()  { log_json "ERROR" "$@" >&2; }

# ── Retry con backoff exponencial ───────────────────────────
retry() {
  local -r desc="$1"; shift
  local n=0 max=4 delay=2
  log "Ejecutando: $desc"
  until "$@"; do
    n=$((n + 1))
    if [[ $n -ge $max ]]; then
      err "FALLÓ tras $max intentos: $desc"
      return 1
    fi
    warn "Intento $n/$max fallido. Reintentando en $((delay ** n))s..."
    sleep $((delay ** n))
  done
}

# ── Cleanup en caso de error ─────────────────────────────────
cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    err "Deploy fallido (exit=$exit_code) en línea ${BASH_LINENO[0]}"
    if [[ "$DRY_RUN" == "false" ]]; then
      warn "Eliminando RG $RG por cleanup..."
      az group delete --name "$RG" --yes --no-wait 2>/dev/null || true
    fi
  fi
}
trap cleanup ERR
trap 'log "Script finalizado. Log: $LOG_FILE"' EXIT

# ── Verificar prerequisitos ──────────────────────────────────
check_prereqs() {
  log "Verificando prerequisitos..."
  command -v az    &>/dev/null || { err "Azure CLI no encontrado"; exit 127; }
  command -v jq    &>/dev/null || { err "jq no encontrado";         exit 127; }
  az account show &>/dev/null || {
    err "No autenticado — ejecutar: az login"
    exit 1
  }
  local sub
  sub=$(az account show --query name --output tsv)
  log "Suscripción activa: $sub"
}

# ── Funciones de infraestructura (idempotentes) ─────────────
ensure_rg() {
  log "Verificando Resource Group $RG..."
  if az group show --name "$RG" &>/dev/null; then
    log "RG $RG ya existe — omitiendo creación"
  else
    log "Creando RG $RG en $LOCATION..."
    retry "crear RG" az group create \
      --name "$RG" --location "$LOCATION" \
      --tags environment=lab managed_by=script
  fi
}

ensure_vnet() {
  log "Verificando VNet $VNET_NAME..."
  if az network vnet show -g "$RG" -n "$VNET_NAME" &>/dev/null; then
    log "VNet $VNET_NAME ya existe"
  else
    retry "crear VNet" az network vnet create \
      --resource-group "$RG" --name "$VNET_NAME" \
      --address-prefix "10.40.0.0/16"
    retry "crear Subnet" az network vnet subnet create \
      --resource-group "$RG" \
      --vnet-name "$VNET_NAME" \
      --name "$SUBNET_NAME" \
      --address-prefix "10.40.1.0/24"
  fi
}

ensure_nsg() {
  log "Configurando NSG $NSG_NAME..."
  az network nsg show -g "$RG" -n "$NSG_NAME" &>/dev/null || \
    az network nsg create -g "$RG" -n "$NSG_NAME"

  # Regla SSH solo si no existe
  az network nsg rule show -g "$RG" --nsg-name "$NSG_NAME" \
    -n "AllowSSH" &>/dev/null || \
    az network nsg rule create \
      --resource-group "$RG" --nsg-name "$NSG_NAME" \
      --name "AllowSSH" --priority 100 \
      --protocol Tcp --destination-port-range 22 \
      --source-address-prefixes "$(curl -s https://api.ipify.org)"

  # Asociar NSG a subnet
  az network vnet subnet update \
    --resource-group "$RG" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --network-security-group "$NSG_NAME"
}

ensure_vm() {
  log "Verificando VM $VM_NAME..."
  if az vm show -g "$RG" -n "$VM_NAME" &>/dev/null; then
    log "VM $VM_NAME ya existe"
    return 0
  fi

  # Leer password desde Key Vault (no hardcodeado)
  log "Leyendo credenciales desde Key Vault $KV_NAME..."
  local vm_pass
  vm_pass=$(az keyvault secret show \
    --vault-name "$KV_NAME" --name "vm-admin-password" \
    --query value --output tsv)

  local subnet_id
  subnet_id=$(az network vnet subnet show \
    --resource-group "$RG" --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" --query id --output tsv)

  retry "crear VM" az vm create \
    --resource-group "$RG" \
    --name "$VM_NAME" \
    --image "Ubuntu2204" \
    --size "Standard_D2s_v3" \
    --admin-username "labadmin" \
    --admin-password "$vm_pass" \
    --subnet "$subnet_id" \
    

  # Obtener IP privada para el resumen
  local private_ip
  private_ip=$(az vm show -g "$RG" -n "$VM_NAME" \
    --show-details --query privateIps --output tsv)
  log "VM creada. IP privada: $private_ip"
}

ensure_storage() {
  log "Verificando Storage Account $ST_NAME..."
  az storage account show --name "$ST_NAME" &>/dev/null || \
    retry "crear Storage" az storage account create \
      --name "$ST_NAME" --resource-group "$RG" \
      --sku Standard_LRS --min-tls-version TLS1_2 \
      --allow-blob-public-access false

  # Crear container de logs si no existe
  az storage container show --name "deployments" \
    --account-name "$ST_NAME" --auth-mode login &>/dev/null || \
    az storage container create \
      --name "deployments" \
      --account-name "$ST_NAME" \
      --auth-mode login

  # Subir log actual al blob
  az storage blob upload \
    --account-name "$ST_NAME" \
    --container-name "deployments" \
    --name "deploy-$(date +%Y%m%d-%H%M%S).log" \
    --file "$LOG_FILE" \
    --auth-mode login
  log "Log de deploy subido al Storage Account"
}

# ── Destruir infraestructura ─────────────────────────────────
destroy_infra() {
  warn "DESTRUYENDO toda la infraestructura del RG $RG..."
  read -r -p "¿Confirmar? (yes/no): " confirm
  [[ "$confirm" == "yes" ]] || { log "Cancelado"; exit 0; }
  az group delete --name "$RG" --yes
  log "Infraestructura eliminada"
}

# ── Main ─────────────────────────────────────────────────────
main() {
  log "=== INICIO DEL DEPLOY ==="
  log "Modo: DRY_RUN=$DRY_RUN | DESTROY=$DESTROY"
  check_prereqs

  if [[ "$DESTROY" == "true" ]]; then
    destroy_infra
    exit 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY RUN: Se ejecutaría el deploy sobre RG=$RG en $LOCATION"
    exit 0
  fi

  ensure_rg
  ensure_vnet
  ensure_nsg
  ensure_vm
  ensure_storage

  log "=== DEPLOY COMPLETADO ==="
  TOTAL=$(az resource list -g "$RG" --query "length(@)" --output tsv)
  log "Recursos en RG: $TOTAL"
}

main "$@"
