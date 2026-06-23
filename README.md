# Semana 11 — Automatización Avanzada con Azure CLI
## Script Completo de Despliegue de Infraestructura

---

## 0. Prerrequisitos

> **IMPORTANTE:** Este laboratorio requiere **WSL2 con Ubuntu** en Windows para correr los scripts Bash.

**Instalar WSL2 (si no lo tienes):**
```powershell
# En PowerShell como Administrador:
wsl --install -d Ubuntu-22.04
```

Reinicia el PC, abre Ubuntu desde el menú inicio y crea tu usuario.

**Dentro de WSL2/Ubuntu, instalar dependencias:**
```bash
# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# jq
sudo apt-get install -y jq

# shellcheck
sudo apt-get install -y shellcheck

# Verificar todo
az --version | head -1
bash --version | head -1
shellcheck --version
jq --version
```

---

## Estructura del proyecto

```
lab-semana11/
├── scripts/
│   ├── deploy.sh        # Script Bash principal (Partes B, C, D)
│   ├── deploy.ps1       # Equivalente PowerShell
│   ├── validate.sh      # Validación post-deploy (Parte D)
│   └── monitor.sh       # Monitoreo continuo (ejercicio avanzado)
├── .github/
│   └── workflows/
│       └── deploy.yml   # Pipeline GitHub Actions (Parte E)
└── README.md
```

---

## Parte A — Preparación del entorno

**1. Copiar esta carpeta a WSL2:**

Desde PowerShell:
```powershell
# Copiar la carpeta al home de WSL2
cp -r C:\Users\TU_USUARIO\Desktop\lab-semana11 \\wsl$\Ubuntu-22.04\home\TU_USUARIO_WSL\
```

O desde dentro de WSL2:
```bash
cp -r /mnt/c/Users/TU_USUARIO/Desktop/lab-semana11 ~/lab-semana11
cd ~/lab-semana11
```

**2. Dar permisos de ejecución:**
```bash
chmod +x scripts/deploy.sh scripts/validate.sh scripts/monitor.sh
```

**3. Autenticarse en Azure:**
```bash
az login
az account show --output table
```

**4. Crear Key Vault y guardar la password de la VM:**
```bash
SUFFIX="josua01"    # Cambia por tu sufijo
KV_NAME="kv-lab-auto-${SUFFIX}"

az group create --name rg-lab-autodeploy --location eastus2

az keyvault create \
  --name "$KV_NAME" \
  --resource-group rg-lab-autodeploy \
  --location eastus2 \
  --sku standard

az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name "vm-admin-password" \
  --value "P@ssw0rd123!Lab"
```

**5. Verificar el script con shellcheck:**
```bash
shellcheck scripts/deploy.sh
# Si no hay salida: sin errores
```

---

## Parte B — Dry Run

```bash
export SUFFIX="josua01"
./scripts/deploy.sh --dry-run
```

Salida esperada:
```json
{"time":"...","level":"INFO","msg":"=== INICIO DEL DEPLOY ===","script":"deploy.sh"}
{"time":"...","level":"INFO","msg":"Modo: DRY_RUN=true | DESTROY=false",...}
{"time":"...","level":"INFO","msg":"DRY RUN: Se ejecutaría el deploy sobre RG=rg-lab-autodeploy en eastus2",...}
```

---

## Parte C — Deploy completo

```bash
export SUFFIX="josua01"
./scripts/deploy.sh
```

Monitorear el log en tiempo real (abre otra terminal WSL2):
```bash
tail -f deploy-*.log | jq .
```

Tarda aprox. 8-12 minutos (la VM es lo más lento).

**Probar idempotencia** — volver a ejecutar el mismo script:
```bash
./scripts/deploy.sh
# Debe terminar en segundos con mensajes "ya existe"
```

---

## Parte D — Validar el deploy

```bash
export SUFFIX="josua01"
export RG="rg-lab-autodeploy"
./scripts/validate.sh
```

Salida esperada:
```
✅ Resource Group
✅ VNet
✅ Subnet snet-web
✅ NSG nsg-web
✅ VM running
✅ Storage Account

Resultados: 6 OK / 0 FALLIDO
```

También validar con CLI:
```bash
az resource list --resource-group rg-lab-autodeploy --output table

az storage blob list \
  --container-name deployments \
  --account-name "stlabautodeploy${SUFFIX}" \
  --auth-mode key \
  --output table
```

---

## Parte E — GitHub Actions con OIDC

```bash
# 1. Crear App Registration
APP_ID=$(az ad app create --display-name "github-deploy-lab" \
  --query appId --output tsv)
SP_ID=$(az ad sp create --id "$APP_ID" --query id --output tsv)

# 2. Asignar rol Contributor
SUB_ID=$(az account show --query id --output tsv)
az role assignment create \
  --assignee "$SP_ID" \
  --role Contributor \
  --scope "/subscriptions/$SUB_ID"

# 3. Crear Federated Credential (reemplaza TU_ORG y TU_REPO)
az ad app federated-credential create --id "$APP_ID" \
  --parameters '{
    "name": "github-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:TU_ORG/lab-semana11:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'

# 4. Ver los valores para agregar en GitHub Secrets
echo "AZURE_CLIENT_ID      = $APP_ID"
echo "AZURE_TENANT_ID      = $(az account show --query tenantId -o tsv)"
echo "AZURE_SUBSCRIPTION_ID = $SUB_ID"
```

En GitHub: Settings → Secrets and variables → Actions → agregar los 3 secrets.

Hacer push:
```bash
git init
git add -A
git commit -m "feat: deploy script lab semana11"
git remote add origin https://github.com/TU_ORG/lab-semana11.git
git push origin main
```

---

## Limpieza de recursos

```bash
# Opción 1: flag --destroy del script
export SUFFIX="josua01"
./scripts/deploy.sh --destroy

# Opción 2: directo con CLI
az group delete --name rg-lab-autodeploy --yes --no-wait

# Limpiar App Registration de OIDC
az ad app delete --id "$APP_ID"
```

---

## Preguntas de evaluación

**1.** El script usa `set -euo pipefail`. Explica qué sucede si un comando de `az network vnet show` falla con exit code 1 porque el recurso no existe. ¿Por qué se usa `&>/dev/null ||` en la función `ensure_vnet`?

**Respuesta:** `set -e` hace que el script termine inmediatamente si cualquier comando retorna exit code distinto de 0. Si `az network vnet show` falla (el recurso no existe), sin `&>/dev/null ||` el script terminaría abruptamente. El `&>/dev/null` suprime el mensaje de error de Azure en stdout y stderr, y el `||` convierte el fallo en una condición que el `if` puede evaluar — si falla, ejecuta el bloque `else` para crear el recurso. Esto permite implementar idempotencia: verificar si existe sin que el fallo de la verificación mate el script.

**2.** La función `retry()` usa `sleep $((delay ** n))`. Si `delay=2` y el máximo de reintentos es 4, ¿cuánto tiempo total esperará el script?

**Respuesta:** Los reintentos son n=1, n=2, n=3 (el cuarto intento es el fallo final, sin sleep). Los tiempos son: 2¹=2s, 2²=4s, 2³=8s. Total acumulado: **14 segundos** de espera antes de declarar fallo.

**3.** El workflow usa `permissions: id-token: write` para OIDC. ¿Por qué es más seguro que guardar `AZURE_CLIENT_SECRET`?

**Respuesta:** Un `CLIENT_SECRET` es una credencial de larga duración — si se expone (leak en logs, repositorio público), un atacante puede usarla indefinidamente hasta que expire o se revoque manualmente. El token OIDC es de vida corta (minutos), generado automáticamente por GitHub para ese job específico y con alcance limitado al repositorio y rama configurados en la Federated Credential. Cuando el job termina, el token expira automáticamente y no puede reutilizarse.

**4.** Si `vm_pass` se imprime accidentalmente con `echo` en los logs del pipeline, ¿cómo lo evitarías?

**Respuesta:** En GitHub Actions, agregar el valor como secret enmascarado: `echo "::add-mask::$vm_pass"` inmediatamente después de leerlo del Key Vault. GitHub Actions reemplaza cualquier aparición del valor en los logs con `***`. Adicionalmente, activar `set +x` antes de leer el secreto (si se usa modo debug) y `set -x` después.

**5.** Si la VM existe pero está en estado `stopped`, ¿qué retornaría el check `VM running`?

**Respuesta:** Retornaría `❌ VM running`. El comando `az vm get-instance-view` devolvería `PowerState/deallocated` o `PowerState/stopped` en lugar de `PowerState/running`, por lo que el `grep -q "running"` fallaría con exit code 1, y la función `check()` incrementaría `$FAIL` en lugar de `$PASS`.

**6.** Compara la idempotencia del script Bash con la de Terraform. ¿Cuándo preferirías scripts shell?

**Respuesta:** Terraform gestiona idempotencia mediante el state file — compara el estado deseado con el actual y solo actúa sobre diferencias. El script Bash implementa idempotencia manualmente con verificaciones `if az resource show ... &>/dev/null`. Terraform es más confiable para infraestructura de larga vida (detecta drift automáticamente). Los scripts shell son preferibles para: tareas operativas puntuales (rotación de secretos, backups), integración con sistemas que no tienen provider Terraform, lógica condicional compleja que HCL no soporta bien, o cuando el equipo no conoce Terraform y ya domina bash/CLI.

---

## Referencias

- Azure CLI: https://learn.microsoft.com/en-us/cli/azure/
- JMESPath query: https://learn.microsoft.com/en-us/cli/azure/query-azure-cli
- GitHub Actions OIDC + Azure: https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect
- Az PowerShell: https://learn.microsoft.com/en-us/powershell/azure/
- ShellCheck: https://www.shellcheck.net
- set -euo pipefail: https://wiki.bash-hackers.org/commands/builtin/set
