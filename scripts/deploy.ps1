#Requires -Modules Az
# deploy.ps1 — Despliegue de infraestructura Azure con PowerShell
[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$Location  = "eastus2",
  [string]$Suffix    = "lab01",
  [switch]$Destroy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RG       = "rg-lab-autodeploy"
$VNetName = "vnet-lab"
$VMName   = "vm-lab-auto"
$StName   = "stlabautodeploy$Suffix"
$KvName   = "kv-lab-auto-$Suffix"
$LogFile  = "deploy-$(Get-Date -Format yyyyMMdd-HHmmss).log"

function Write-Log {
  param([string]$Msg, [string]$Level = "INFO")
  $entry = [PSCustomObject]@{
    time   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    level  = $Level
    msg    = $Msg
    script = "deploy.ps1"
  } | ConvertTo-Json -Compress
  $entry | Tee-Object -Append -FilePath $LogFile
}

function Invoke-WithRetry {
  param([scriptblock]$Action, [string]$Description, [int]$MaxRetries = 3)
  $attempt = 0
  do {
    try {
      Write-Log "Ejecutando: $Description"
      & $Action
      return
    } catch {
      $attempt++
      if ($attempt -ge $MaxRetries) { throw }
      $delay = [math]::Pow(2, $attempt)
      Write-Log "Reintentando en ${delay}s... ($attempt/$MaxRetries)" "WARN"
      Start-Sleep -Seconds $delay
    }
  } while ($attempt -lt $MaxRetries)
}

function Confirm-RG {
  if (-not (Get-AzResourceGroup -Name $RG -ErrorAction SilentlyContinue)) {
    Write-Log "Creando Resource Group $RG..."
    Invoke-WithRetry -Description "crear RG" -Action {
      New-AzResourceGroup -Name $RG -Location $Location `
        -Tag @{environment="lab"; managed_by="script"}
    }
  } else { Write-Log "RG $RG ya existe" }
}

function Confirm-VNet {
  $vnet = Get-AzVirtualNetwork -ResourceGroupName $RG -Name $VNetName -ErrorAction SilentlyContinue
  if (-not $vnet) {
    Write-Log "Creando VNet $VNetName..."
    Invoke-WithRetry -Description "crear VNet" -Action {
      $subnet = New-AzVirtualNetworkSubnetConfig -Name "snet-web" -AddressPrefix "10.40.1.0/24"
      New-AzVirtualNetwork -Name $VNetName -ResourceGroupName $RG `
        -Location $Location -AddressPrefix "10.40.0.0/16" -Subnet $subnet
    }
  } else { Write-Log "VNet $VNetName ya existe" }
}

function Confirm-VM {
  if (Get-AzVM -ResourceGroupName $RG -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Log "VM $VMName ya existe"
    return
  }

  # Leer password desde Key Vault
  $vmPass  = (Get-AzKeyVaultSecret -VaultName $KvName -Name "vm-admin-password" -AsPlainText)
  $secPass = ConvertTo-SecureString $vmPass -AsPlainText -Force
  $cred    = New-Object PSCredential("labadmin", $secPass)

  Write-Log "Creando VM $VMName..."
  Invoke-WithRetry -Description "crear VM" -Action {
    New-AzVM -ResourceGroupName $RG -Name $VMName `
      -Location $Location -Credential $cred `
      -Size "Standard_D2s_v3" `
      -Image "Ubuntu2204"
  }
}

function Remove-Infra {
  Write-Log "DESTRUYENDO infraestructura del RG $RG..." "WARN"
  $confirm = Read-Host "¿Confirmar? (yes/no)"
  if ($confirm -ne "yes") { Write-Log "Cancelado"; return }
  Remove-AzResourceGroup -Name $RG -Force
  Write-Log "Infraestructura eliminada"
}

# ── Main ─────────────────────────────────────────────────────
Write-Log "=== INICIO DEL DEPLOY (PowerShell) ==="

# En CI/CD usar Managed Identity; localmente usar Connect-AzAccount interactivo
if ($env:CI) {
  Connect-AzAccount -Identity
} else {
  Connect-AzAccount
}

if ($Destroy) {
  Remove-Infra
  exit 0
}

Confirm-RG
Confirm-VNet
Confirm-VM

Write-Log "=== DEPLOY COMPLETADO ==="
